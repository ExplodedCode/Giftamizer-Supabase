-- Items move from "one image per item" (items.image_token flag + a single
-- storage object named after the item id) to "many images per item"
-- (one item_images row per image + storage objects nested under the item,
-- e.g. items/{itemId}/{imageId}).
--
-- This file only changes the schema/RLS/backfills the new rows - it does
-- NOT move the actual bytes in Storage (SQL can't do that; storage.objects
-- rows don't own the file, the object store does). After applying this
-- file, run the companion scripts/migrate-item-images.mjs script (service
-- role key) to physically move every existing items/{itemId} object to
-- items/{itemId}/{itemImagesId}, THEN deploy the new frontend. Do not
-- deploy the new frontend before the script has finished - the old flat
-- object path is no longer served by any policy below, so images would
-- 404 in the gap. items.image_token and the old on_item_delete_image
-- trigger are deliberately left in place here; they're dropped in
-- 0015-item-images-cleanup.sql only once the move script + frontend are
-- confirmed working.

CREATE TABLE item_images (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  item_id UUID NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
  position INT NOT NULL DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

--
-- item_images RLS - mirrors items' own RLS block (0005-items.sql) exactly,
-- scoped through item_images.item_id/user_id instead of items.id/user_id.
alter table item_images enable row level security;

create policy "Users can view own item_images"
  ON item_images for select
  TO authenticated
  using (user_id = auth.uid());
-- Insert/update must also prove the parent item is the caller's own, not just
-- that the row's user_id is: otherwise a user could attach rows to someone
-- else's item (or repoint their own row at one), which group members would
-- then see as ghost images on that item. (is_item_owner is SECURITY DEFINER,
-- so it can read items regardless of the caller's RLS.)
create policy "Users can add own item_images"
  ON item_images for insert
  TO authenticated
  with check (user_id = auth.uid() AND is_item_owner(item_id, auth.uid()));
create policy "Users can update own item_images"
  ON item_images for update
  TO authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() AND is_item_owner(item_id, auth.uid()));
create policy "Users can delete own item_images"
  ON item_images for delete
  TO authenticated
  using (user_id = auth.uid());
-- Allow group members to select item_images, same shape as "Group members
-- can select items" on public.items.
CREATE POLICY "Group members can select item_images"
  ON item_images for select
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM profiles
      WHERE
        profiles.user_id = item_images.user_id
        AND profiles.enable_lists = false
    ) OR (
      EXISTS (
        SELECT 1
        FROM group_members
        JOIN lists_groups ON lists_groups.group_id = group_members.group_id
        JOIN items_lists ON items_lists.list_id = lists_groups.list_id
        WHERE
          group_members.user_id = auth.uid()
          AND items_lists.item_id = item_images.item_id
      )
    )
  );

--
-- Storage RLS: items bucket objects now live at "{itemId}/{imageId}"
-- instead of "{itemId}". storage.foldername(name) is Supabase's built-in
-- helper returning the path segments before the filename, so
-- (storage.foldername(name))[1] is the item id segment. Still run through
-- try_cast_uuid defensively (0011's rationale: a hand-uploaded/malformed
-- object name must not crash every request against the bucket).
DROP POLICY IF EXISTS "allow item image select" ON storage.objects;
CREATE POLICY "allow item image select"
  ON storage.objects
  AS PERMISSIVE
  FOR SELECT
  TO authenticated
  USING (
    (bucket_id = 'items'::text)
    AND (
      is_item_owner(try_cast_uuid((storage.foldername(objects.name))[1]), auth.uid())
      OR EXISTS (
        SELECT 1 FROM items
        JOIN profiles ON profiles.user_id = items.user_id
        WHERE items.id = try_cast_uuid((storage.foldername(objects.name))[1]) AND profiles.enable_lists = false
      )
      OR EXISTS (
        SELECT 1
        FROM group_members
        JOIN lists_groups ON lists_groups.group_id = group_members.group_id
        JOIN items_lists ON items_lists.list_id = lists_groups.list_id
        WHERE group_members.user_id = auth.uid() AND items_lists.item_id = try_cast_uuid((storage.foldername(objects.name))[1])
      )
    )
  );

DROP POLICY IF EXISTS "allow item image insert" ON storage.objects;
CREATE POLICY "allow item image insert"
  ON storage.objects
  AS PERMISSIVE
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (bucket_id = 'items'::text) AND is_item_owner(try_cast_uuid((storage.foldername(objects.name))[1]), auth.uid())
  );

DROP POLICY IF EXISTS "allow item image update" ON storage.objects;
CREATE POLICY "allow item image update"
  ON storage.objects
  AS PERMISSIVE
  FOR UPDATE
  TO authenticated
  USING (
    (bucket_id = 'items'::text) AND is_item_owner(try_cast_uuid((storage.foldername(objects.name))[1]), auth.uid())
  );

DROP POLICY IF EXISTS "allow item image delete" ON storage.objects;
CREATE POLICY "allow item image delete"
  ON storage.objects
  AS PERMISSIVE
  FOR DELETE
  TO authenticated
  USING (
    (bucket_id = 'items'::text) AND is_item_owner(try_cast_uuid((storage.foldername(objects.name))[1]), auth.uid())
  );

--
-- Per-image delete cascade. item_images rows disappear either directly
-- (user removes one image) or via items.id ON DELETE CASCADE (whole item
-- deleted) - either way this fires once per row, so a single per-row
-- handler covers both cases without a separate prefix/list-based delete.
CREATE OR REPLACE FUNCTION handle_item_image_delete()
RETURNS trigger
SECURITY DEFINER AS $$
BEGIN
  PERFORM public.delete_from_bucket('items'::text, OLD.item_id::text || '/' || OLD.id::text);
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER on_item_image_delete
AFTER DELETE ON item_images
FOR EACH ROW
EXECUTE FUNCTION handle_item_image_delete();

--
-- Backfill: one item_images row per item that currently has an image.
-- This only creates the DB row/id - see the file header for the required
-- companion script that moves the actual storage object to match.
INSERT INTO item_images (item_id, user_id, position)
SELECT id, user_id, 0 FROM items WHERE image_token IS NOT NULL;
