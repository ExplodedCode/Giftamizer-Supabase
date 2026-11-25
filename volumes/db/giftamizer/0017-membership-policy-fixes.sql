-- Group membership and invite access fixes. All statements are safe to re-run.
--
-- The first two policies compared a column to itself. Both had a subquery on
-- group_members containing `group_members.group_id = group_id`: the
-- unqualified group_id resolves to the *subquery's* group_members, not to the
-- row being checked, so the group was never actually compared (pg_policies
-- shows it as `group_members_1.group_id = group_members_1.group_id`).
--
-- "Owner can delete members or user can leave group" (0003) contains the same
-- expression, but is not affected: its `group_id IN (SELECT group_id ...)`
-- already limits the delete to groups the caller owns.

-- 1) group_members INSERT: owning *any* group was enough to add anyone to
--    *every* group, including adding yourself as an owner of it.
DROP POLICY IF EXISTS "Owners can add members" ON group_members;
CREATE POLICY "Owners can add members"
  ON group_members FOR INSERT
  TO authenticated
  WITH CHECK (
    is_group_owner(group_id, auth.uid())
  );

-- 2) external_invites UPDATE: any invite could be targeted by a member of any
--    group, and WITH CHECK only looks at the *new* group_id. An owner of one
--    group could move another group's pending invites into their own.
DROP POLICY IF EXISTS "Owners can modify invites & permissions" ON external_invites;
CREATE POLICY "Owners can modify invites & permissions"
  ON external_invites FOR UPDATE
  TO authenticated
  USING (
    is_group_owner(group_id, auth.uid())
  )
  WITH CHECK (
    is_group_owner(group_id, auth.uid())
  );

-- 3) external_invites SELECT was `true`: any signed-in user could read the
--    email address of every pending invite in every group. Limited to members
--    of the group, the same rule group_members uses.
DROP POLICY IF EXISTS "Any can view invites" ON external_invites;
DROP POLICY IF EXISTS "Members can view invites" ON external_invites;
CREATE POLICY "Members can view invites"
  ON external_invites FOR SELECT
  TO authenticated
  USING (
    is_group_member(group_id, auth.uid())
  );

-- 4) accept_link_invite() bypasses RLS but trusted its _user_id argument, and
--    was callable without signing in: anyone with a group's id could add any
--    user to it (while invite_link is on). Callers can now only add themselves.
--    The signature is unchanged because the frontend passes both arguments.
CREATE OR REPLACE FUNCTION public.accept_link_invite(_group_id uuid, _user_id uuid) RETURNS TABLE(group_id uuid, user_id uuid)
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
BEGIN
  IF auth.uid() IS NULL OR _user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Not allowed to accept an invite for another user!' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM groups WHERE id = _group_id AND invite_link = true) THEN
    RAISE EXCEPTION 'Group invite does not exist!';
  END IF;

  INSERT INTO group_members (group_id, user_id, owner, invite)
  VALUES (_group_id, _user_id, false, false);

  RETURN QUERY
  SELECT _group_id as group_id, _user_id as user_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.accept_link_invite(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_link_invite(uuid, uuid) TO authenticated;

-- 5) is_group_owner() was VOLATILE (the default), so it saw rows already
--    changed by the running statement. Saving several members at once (one
--    upsert) while giving up your own ownership failed: after your row was
--    demoted, every later row was rejected. STABLE evaluates ownership as of
--    the start of the statement, so the result no longer depends on row order.
ALTER FUNCTION public.is_group_owner(uuid, uuid) STABLE;
