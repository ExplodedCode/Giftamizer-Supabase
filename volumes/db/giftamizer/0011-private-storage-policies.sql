-- Storage buckets used to be marked public (readable by anyone with the URL,
-- no auth required) as a workaround. That's real exposure: filenames are just
-- entity UUIDs, so anyone who could guess/observe one could view the file
-- with no relationship to it at all.
--
-- Buckets stay private (public = false) from here on. These SELECT policies
-- replace the narrower owner-only ones from 0001/0003/0005 so that anyone who
-- can already see an item/list/group/profile in the app can also view its
-- image - via a signed URL (client.storage.from(bucket).createSignedUrl(...)),
-- which itself only succeeds if the requesting user's own session passes
-- these policies. INSERT/UPDATE/DELETE stay owner-only, unchanged.

-- On a brand-new install, storage.buckets.public doesn't exist yet at this
-- point - it's added later by the storage-api service's own migrations,
-- same as the bucket inserts in 0001/0003/0005 (see their comments). Skip
-- here rather than crash the whole init pass; re-run this UPDATE via
-- Studio's SQL editor after first boot to make sure buckets end up private.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'storage' AND table_name = 'buckets' AND column_name = 'public'
  ) THEN
    UPDATE storage.buckets SET public = false WHERE id IN ('avatars', 'groups', 'items', 'lists');
  END IF;
END $$;

-- storage.objects.name is a free-form text column, not constrained to be a
-- uuid (e.g. a file uploaded by hand via Studio could be named anything).
-- Postgres does not guarantee bucket_id is checked before the rest of a
-- policy's USING clause runs for every row it considers, so a single
-- non-uuid name in the groups/items buckets can crash every request against
-- that bucket for every user with "invalid input syntax for type uuid".
-- Cast defensively everywhere below instead of name::uuid directly.
CREATE OR REPLACE FUNCTION public.try_cast_uuid(_value text) RETURNS uuid
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN _value::uuid;
EXCEPTION WHEN invalid_text_representation THEN
  RETURN NULL;
END;
$$;

-- avatars: any signed-in user can view any avatar, matching the openness
-- public.profiles already has ("Any one can view profiles" USING (true)).
DROP POLICY IF EXISTS "allow user select" ON storage.objects;
CREATE POLICY "allow user select"
  ON storage.objects
  AS PERMISSIVE
  FOR SELECT
  TO authenticated
  USING (bucket_id = 'avatars'::text);

-- groups: any group member can view the group image (previously owner-only,
-- which was only masked by the bucket being public).
DROP POLICY IF EXISTS "allow group image select" ON storage.objects;
CREATE POLICY "allow group image select"
  ON storage.objects
  AS PERMISSIVE
  FOR SELECT
  TO authenticated
  USING (
    (bucket_id = 'groups'::text)
    AND is_group_member(try_cast_uuid(objects.name), auth.uid())
  );

-- items: mirrors "Users can view own items" + "Group members can select
-- items" on public.items.
DROP POLICY IF EXISTS "allow item image select" ON storage.objects;
CREATE POLICY "allow item image select"
  ON storage.objects
  AS PERMISSIVE
  FOR SELECT
  TO authenticated
  USING (
    (bucket_id = 'items'::text)
    AND (
      is_item_owner(try_cast_uuid(objects.name), auth.uid())
      OR EXISTS (
        SELECT 1 FROM items
        JOIN profiles ON profiles.user_id = items.user_id
        -- objects.name must be qualified here: items also has its own "name"
        -- column (the item's title), which would otherwise silently shadow
        -- the intended outer storage.objects.name reference.
        WHERE items.id = try_cast_uuid(objects.name) AND profiles.enable_lists = false
      )
      OR EXISTS (
        SELECT 1
        FROM group_members
        JOIN lists_groups ON lists_groups.group_id = group_members.group_id
        JOIN items_lists ON items_lists.list_id = lists_groups.list_id
        WHERE group_members.user_id = auth.uid() AND items_lists.item_id = try_cast_uuid(objects.name)
      )
    )
  );

-- groups/items INSERT/UPDATE/DELETE policies (defined in 0003/0005) have the
-- same unguarded name::uuid cast in their USING/WITH CHECK clauses. Replace
-- them with the safe-cast equivalent too, for the same reason as above.
DROP POLICY IF EXISTS "allow group image insert" ON storage.objects;
CREATE POLICY "allow group image insert"
  ON storage.objects
  AS PERMISSIVE
  FOR INSERT
  TO authenticated
  WITH CHECK (((bucket_id = 'groups'::text) AND is_group_owner(try_cast_uuid(objects.name), auth.uid())));

DROP POLICY IF EXISTS "allow group image update" ON storage.objects;
CREATE POLICY "allow group image update"
  ON storage.objects
  AS PERMISSIVE
  FOR UPDATE
  TO authenticated
  USING (((bucket_id = 'groups'::text)
    AND
    exists (
      select 1 from group_members
      where group_members.user_id = auth.uid() AND group_members.group_id = try_cast_uuid(objects.name) AND group_members.owner = true
    )
   ));

DROP POLICY IF EXISTS "allow group image delete" ON storage.objects;
CREATE POLICY "allow group image delete"
  ON storage.objects
  AS PERMISSIVE
  FOR DELETE
  TO authenticated
  USING (((bucket_id = 'groups'::text)
    AND
    exists (
      select 1 from group_members
      where group_members.user_id = auth.uid() AND group_members.group_id = try_cast_uuid(objects.name) AND group_members.owner = true
    )
   ));

DROP POLICY IF EXISTS "allow item image insert" ON storage.objects;
CREATE POLICY "allow item image insert"
  ON storage.objects
  AS PERMISSIVE
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (bucket_id = 'items'::text) AND is_item_owner(try_cast_uuid(objects.name), auth.uid())
  );

DROP POLICY IF EXISTS "allow item image update" ON storage.objects;
CREATE POLICY "allow item image update"
  ON storage.objects
  AS PERMISSIVE
  FOR UPDATE
  TO authenticated
  USING (
    (bucket_id = 'items'::text) AND is_item_owner(try_cast_uuid(objects.name), auth.uid())
  );

DROP POLICY IF EXISTS "allow item image delete" ON storage.objects;
CREATE POLICY "allow item image delete"
  ON storage.objects
  AS PERMISSIVE
  FOR DELETE
  TO authenticated
  USING (
    (bucket_id = 'items'::text) AND is_item_owner(try_cast_uuid(objects.name), auth.uid())
  );

-- lists: mirrors "Users can view own lists" + "Group members can select
-- lists" on public.lists.
DROP POLICY IF EXISTS "allow list image select" ON storage.objects;
CREATE POLICY "allow list image select"
  ON storage.objects
  AS PERMISSIVE
  FOR SELECT
  TO authenticated
  USING (
    (bucket_id = 'lists'::text)
    AND (
      is_list_owner(objects.name, auth.uid())
      OR EXISTS (
        SELECT 1
        FROM group_members
        JOIN lists_groups ON lists_groups.group_id = group_members.group_id
        WHERE group_members.user_id = auth.uid() AND lists_groups.list_id = objects.name
      )
    )
  );
