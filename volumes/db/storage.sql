ALTER TABLE storage.buckets ADD COLUMN "public" boolean default false;
update storage.buckets set public = true WHERE id = 'avatars' OR id = 'groups' OR id = 'lists' OR id = 'items';