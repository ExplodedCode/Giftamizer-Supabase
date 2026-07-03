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

UPDATE storage.buckets SET public = false WHERE id IN ('avatars', 'groups', 'items', 'lists');

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
    AND is_group_member(name::uuid, auth.uid())
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
      is_item_owner(name::uuid, auth.uid())
      OR EXISTS (
        SELECT 1 FROM items
        JOIN profiles ON profiles.user_id = items.user_id
        WHERE items.id = name::uuid AND profiles.enable_lists = false
      )
      OR EXISTS (
        SELECT 1
        FROM group_members
        JOIN lists_groups ON lists_groups.group_id = group_members.group_id
        JOIN items_lists ON items_lists.list_id = lists_groups.list_id
        WHERE group_members.user_id = auth.uid() AND items_lists.item_id = name::uuid
      )
    )
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
      is_list_owner(name, auth.uid())
      OR EXISTS (
        SELECT 1
        FROM group_members
        JOIN lists_groups ON lists_groups.group_id = group_members.group_id
        WHERE group_members.user_id = auth.uid() AND lists_groups.list_id = name
      )
    )
  );
