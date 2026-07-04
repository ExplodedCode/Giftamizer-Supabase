-- As of supabase/postgres:17.x, the bundled 00000000000002-storage-schema.sql
-- only creates the "storage" schema/role/grants - it no longer creates the
-- storage.buckets/storage.objects tables themselves (that moved entirely to
-- storage-api's own migrations, which run when the storage-api container
-- first connects). Giftamizer's own init scripts (0001-profiles.sql) insert
-- into storage.buckets during this same initdb pass, before storage-api ever
-- starts, so the tables need to exist synchronously here too.
--
-- This mirrors storage-api's own tenant migration
-- (0002-storage-schema.sql) so the shapes match exactly; storage-api's
-- CREATE TABLE IF NOT EXISTS / CREATE OR REPLACE statements are idempotent
-- and will just no-op against what's created here on first boot.

CREATE TABLE IF NOT EXISTS "storage"."buckets" (
    "id" text not NULL,
    "name" text NOT NULL,
    "owner" uuid,
    "created_at" timestamptz DEFAULT now(),
    "updated_at" timestamptz DEFAULT now(),
    PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX IF NOT EXISTS "bname" ON "storage"."buckets" USING BTREE ("name");

CREATE TABLE IF NOT EXISTS "storage"."objects" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid(),
    "bucket_id" text,
    "name" text,
    "owner" uuid,
    "created_at" timestamptz DEFAULT now(),
    "updated_at" timestamptz DEFAULT now(),
    "last_accessed_at" timestamptz DEFAULT now(),
    "metadata" jsonb,
    CONSTRAINT "objects_bucketId_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets"("id"),
    PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX IF NOT EXISTS "bucketid_objname" ON "storage"."objects" USING BTREE ("bucket_id","name");
CREATE INDEX IF NOT EXISTS name_prefix_search ON storage.objects(name text_pattern_ops);

ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION storage.foldername(name text)
 RETURNS text[]
 LANGUAGE plpgsql
AS $function$
DECLARE
_parts text[];
BEGIN
	select string_to_array(name, '/') into _parts;
	return _parts[1:array_length(_parts,1)-1];
END
$function$;

CREATE OR REPLACE FUNCTION storage.filename(name text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
_parts text[];
BEGIN
	select string_to_array(name, '/') into _parts;
	return _parts[array_length(_parts,1)];
END
$function$;

CREATE OR REPLACE FUNCTION storage.extension(name text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
_parts text[];
_filename text;
BEGIN
	select string_to_array(name, '/') into _parts;
	select _parts[array_length(_parts,1)] into _filename;
	return reverse(split_part(reverse(_filename), '.', 1));
END
$function$;

CREATE OR REPLACE FUNCTION storage.search(prefix text, bucketname text, limits int DEFAULT 100, levels int DEFAULT 1, offsets int DEFAULT 0)
 RETURNS TABLE (
    name text,
    id uuid,
    updated_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    last_accessed_at TIMESTAMPTZ,
    metadata jsonb
  )
 LANGUAGE plpgsql
AS $function$
BEGIN
	return query
		with files_folders as (
			select ((string_to_array(objects.name, '/'))[levels]) as folder
			from objects
			where objects.name ilike prefix || '%'
			and bucket_id = bucketname
			GROUP by folder
			limit limits
			offset offsets
		)
		select files_folders.folder as name, objects.id, objects.updated_at, objects.created_at, objects.last_accessed_at, objects.metadata from files_folders
		left join objects
		on prefix || files_folders.folder = objects.name and objects.bucket_id=bucketname;
END
$function$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN
        ALTER TABLE "storage".objects OWNER TO supabase_storage_admin;
        ALTER TABLE "storage".buckets OWNER TO supabase_storage_admin;
        ALTER FUNCTION "storage".foldername(text) OWNER TO supabase_storage_admin;
        ALTER FUNCTION "storage".filename(text) OWNER TO supabase_storage_admin;
        ALTER FUNCTION "storage".extension(text) OWNER TO supabase_storage_admin;
        ALTER FUNCTION "storage".search(text,text,int,int,int) OWNER TO supabase_storage_admin;
    END IF;
END $$;
