-- Two RLS gaps found auditing group access alongside the child-list
-- item-status work (0012). Unrelated to that feature, but real - both
-- confirmed by impersonating actual users against the live policies.

-- 1) group_members UPDATE only checked that the caller was *a* member of
--    the group, not that the row being updated was their own. The WITH
--    CHECK only protected the `owner` column, so any regular member could
--    edit any *other* member's `pinned`/`invite` flags. Confirmed: had a
--    non-owner member flip another member's `pinned` flag directly.
--    Owners keep full control of any row; regular members are now limited
--    to their own (matches the policy's own name - "... / allow user to
--    pin group" was always meant to mean their own membership).
DROP POLICY IF EXISTS "Owners can modify members & permissions / allow user to pin group" ON group_members;
CREATE POLICY "Owners can modify members & permissions / allow user to pin group"
  ON group_members FOR UPDATE
  TO authenticated
  USING (
    is_group_owner(group_id, auth.uid()) OR user_id = auth.uid()
  )
  WITH CHECK (
	  is_not_updating_owner_field(
		  group_id,
		  user_id,
		  owner
	  ) OR is_group_owner(group_id, auth.uid())
  );

-- 2) groups.SELECT had `OR NOT EXISTS (... group_members ...)`, making any
--    group with zero members visible to every authenticated user, forever
--    - not just during creation. It can't just be deleted though: it's a
--    workaround for a real Postgres ordering issue. useCreateGroup() does
--    `.insert({...}).select('*').single()`, and Postgres checks
--    INSERT ... RETURNING against the SELECT policy *before* the
--    AFTER INSERT trigger (handle_new_group) adds the creator to
--    group_members - so a brand-new group fails its own SELECT policy
--    without some fallback (confirmed by reproducing the failure directly
--    after a first attempt at just removing the clause).
--
--    Real fix: track the creator directly on the row instead of inferring
--    it from group_members. A column default resolves before any trigger
--    or RETURNING check runs, so INSERT ... RETURNING succeeds immediately
--    without depending on the trigger's side effect - and long-term
--    visibility narrows from "everyone, forever, for any group that's ever
--    emptied" down to just the person who actually created it.
ALTER TABLE groups ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES profiles(user_id) ON DELETE SET NULL DEFAULT auth.uid();

-- Backfill for groups that existed before this column (added at ALTER TABLE
-- time with no JWT context, so they all landed NULL): best-effort, prefer
-- the earliest flagged owner, falling back to the earliest member if none.
UPDATE groups g
SET created_by = (
  SELECT gm.user_id FROM group_members gm
  WHERE gm.group_id = g.id
  ORDER BY gm.owner DESC, gm.created_at ASC
  LIMIT 1
)
WHERE g.created_by IS NULL;

DROP POLICY IF EXISTS "Members can view" ON groups;
CREATE POLICY "Members can view"
  ON groups FOR SELECT
  TO authenticated
  USING (
    exists (
      select 1 from group_members
      where group_members.user_id = auth.uid() AND group_members.group_id = groups.id
    )
    OR created_by = auth.uid()
  );

-- Pin created_by to reality while we're introducing it - without this, a
-- client could explicitly pass an arbitrary created_by in the insert body
-- (overriding the default) and misattribute a group to someone else. Low
-- severity (it grants the *victim* extra visibility, not the attacker
-- anything), but cheap to close in the same migration that adds the column.
DROP POLICY IF EXISTS "Anyone can create groups" ON groups;
CREATE POLICY "Anyone can create groups"
  ON groups FOR INSERT
  TO authenticated
  WITH CHECK (created_by = auth.uid());
