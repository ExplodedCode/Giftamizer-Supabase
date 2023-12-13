
--
-- Deletes file in supabase bucket
--
-- Example:
-- SELECT public.delete_from_bucket(
-- 	'bucket_name', 
-- 	'file.txt'
-- );
--

CREATE OR REPLACE FUNCTION public.delete_from_bucket(bucket text, filename text)
RETURNS TABLE (
  http_delete bigint
)
LANGUAGE plpgsql AS $$
DECLARE
  _service_role_key text := (SELECT current_setting from current_setting('custom.service_role_key'));
  _headers_json text := '';
BEGIN
  _headers_json := '{"Authorization": "Bearer ' || _service_role_key || '"}';

  return query SELECT net.http_delete(
    'http://storage:5000/object/' || bucket || '/' || filename,
    headers := _headers_json::JSONB
  );
END;
$$;

--
--
--
-- Triggers

--
--
-- profile image delete
CREATE OR REPLACE FUNCTION handle_profile_delete_image()
RETURNS trigger
SECURITY DEFINER AS $$
BEGIN
  IF (TG_OP = 'UPDATE') THEN
    IF (NEW.avatar_token IS NULL OR NEW.avatar_token = -1) THEN
      PERFORM public.delete_from_bucket('avatars'::text, NEW.user_id::text);
    END IF;
    RETURN NEW;
  ELSE
    PERFORM public.delete_from_bucket('avatars'::text, OLD.user_id::text);
    RETURN NEW;
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER on_profile_delete_image
AFTER UPDATE OR DELETE ON profiles
FOR EACH ROW
EXECUTE FUNCTION handle_profile_delete_image();

--
--
-- item image delete
CREATE OR REPLACE FUNCTION handle_item_delete_image()
RETURNS trigger
SECURITY DEFINER AS $$
BEGIN
  IF (TG_OP = 'UPDATE') THEN
    IF (NEW.image_token IS NULL) THEN
      PERFORM public.delete_from_bucket('items'::text, NEW.id::text);
    END IF;
    RETURN NEW;
  ELSE
    PERFORM public.delete_from_bucket('items'::text, OLD.id::text);
    RETURN NEW;
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER on_item_delete_image
AFTER UPDATE OR DELETE ON items
FOR EACH ROW
EXECUTE FUNCTION handle_item_delete_image();

--
--
-- lists image delete
CREATE OR REPLACE FUNCTION handle_lists_delete_image()
RETURNS trigger
SECURITY DEFINER AS $$
BEGIN
  IF (TG_OP = 'UPDATE') THEN
    IF (NEW.avatar_token IS NULL) THEN
      PERFORM public.delete_from_bucket('lists'::text, NEW.id::text);
    END IF;
    RETURN NEW;
  ELSE
    PERFORM public.delete_from_bucket('lists'::text, OLD.id::text);
    RETURN NEW;
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER on_lists_delete_image
AFTER UPDATE OR DELETE ON lists
FOR EACH ROW
EXECUTE FUNCTION handle_lists_delete_image();

--
--
-- groups image delete
CREATE OR REPLACE FUNCTION handle_groups_delete_image()
RETURNS trigger
SECURITY DEFINER AS $$
BEGIN
  IF (TG_OP = 'UPDATE') THEN
    IF (NEW.image_token IS NULL) THEN
      PERFORM public.delete_from_bucket('groups'::text, NEW.id::text);
    END IF;
    RETURN NEW;
  ELSE
    PERFORM public.delete_from_bucket('groups'::text, OLD.id::text);
    RETURN NEW;
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER on_groups_delete_image
AFTER UPDATE OR DELETE ON groups
FOR EACH ROW
EXECUTE FUNCTION handle_groups_delete_image();
