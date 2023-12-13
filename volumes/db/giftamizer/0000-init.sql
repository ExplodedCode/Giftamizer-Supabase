CREATE EXTENSION IF NOT EXISTS moddatetime SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS http SCHEMA "extensions";

-- Set auth.users.email unique
ALTER TABLE auth.users ADD UNIQUE (email);

-- CREATE TABLE public.tenants (
--   tenant text PRIMARY KEY NOT NULL
-- );

-- -- Insert default production tenant
-- INSERT INTO public.tenants(tenant)
--   VALUES ('_');

-- -- Row Level Security
-- ALTER TABLE public.tenants enable row level security;
-- CREATE POLICY "Any one can view tenants"
--   on public.tenants for select
--   using ( true );


-- -- Gets origin from DB request header and translates to tenant ID
-- CREATE OR REPLACE FUNCTION public.get_tenant()
-- RETURNS text
-- LANGUAGE plpgsql
-- AS $$
-- DECLARE
--   _tenant text := '';
-- BEGIN
--   _tenant := replace((SELECT split_part(split_part((coalesce(current_setting('request.headers', TRUE), '{}')::JSONB ->> 'origin'), '://',2), 'giftamizer.com', 1)), '.', '_');
  
--   IF length(_tenant) = 0 THEN
--     _tenant := '_';
--   END IF;
  
--   IF NOT EXISTS (SELECT 1 FROM tenants WHERE tenant = _tenant) THEN
--     RAISE EXCEPTION 'Tenant does not exist!'; 
--   END IF;
  
--   RETURN _tenant;
-- END;
-- $$;


-- -- Create a profile for each user when a new tenant is created
-- CREATE OR REPLACE FUNCTION handle_tenant_create()
-- RETURNS TRIGGER AS $$
-- BEGIN
--   INSERT INTO profiles (tenant, user_id, email, first_name, last_name, bio, home, enable_lists, enable_archive, enable_trash, enable_snowfall, email_promotional, email_invites, tour, avatar_token, created_at, updated_at)
--   SELECT NEW.tenant, user_id, email, first_name, last_name, bio, home, enable_lists, enable_archive, enable_trash, enable_snowfall, email_promotional, email_invites, tour, avatar_token, created_at, updated_at
--   FROM profiles WHERE tenant = '_';

--   RETURN NEW;  
-- END;
-- $$ LANGUAGE plpgsql;
-- CREATE TRIGGER on_tenant_create
-- AFTER INSERT ON tenants
-- FOR EACH ROW EXECUTE PROCEDURE handle_tenant_create();