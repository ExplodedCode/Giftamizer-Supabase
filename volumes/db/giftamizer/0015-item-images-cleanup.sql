-- Cleanup step for the item multi-image migration. Apply this ONLY after:
--   1. 0014-item-multi-images.sql has been applied,
--   2. scripts/migrate-item-images.mjs has finished moving every existing
--      item image object to its new "{itemId}/{itemImagesId}" path, and
--   3. the new frontend (reading item_images instead of items.image_token)
--      is deployed and confirmed working.
--
-- Splitting this into its own file rather than folding it into 0014 means a
-- mistake in the risky "physically move files" step can't leave the DB in a
-- state where items.image_token is already gone but files weren't moved yet.

DROP TRIGGER IF EXISTS on_item_delete_image ON items;
DROP FUNCTION IF EXISTS handle_item_delete_image();

ALTER TABLE items DROP COLUMN IF EXISTS image_token;
