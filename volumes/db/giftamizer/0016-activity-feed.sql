-- Activity feed: a history of changes made by *other* people, shown on the
-- Feed page.
--
-- Design notes
--  * Every event is recorded by an AFTER trigger, so it is captured no matter
--    which client / RPC / edge function made the change. No edge function
--    changes are needed.
--  * public.activity has RLS enabled and NO policies, and its privileges are
--    revoked from anon/authenticated. Clients can only read it through
--    get_feed() / get_feed_unread_count(), which decide visibility at READ
--    time. That way an event disappears from a viewer's feed automatically
--    when an item is unshared, archived, or the viewer leaves the group.
--  * Item events carry no group_id: an item can be visible in several groups.
--    The matching groups are computed in the feed_events view.
--  * The visibility joins compare BOTH list_id and user_id (the items RLS only
--    compares list_id, so one user's 'default' list matches everyone's) and
--    require accepted membership (invite = false) on both sides.
--  * Secret Santa events NEVER copy groups.secret_santa->'drawing'.
--  * Claims stay private: a claimed item's removal is only ever logged with
--    audience_user_id = the claimer. items.updated_at (bumped by the
--    items_status trigger on every claim) is deliberately ignored, otherwise
--    claiming would leak into the owner's view as an "edit".
--
-- Safe to re-run: uses IF NOT EXISTS / CREATE OR REPLACE / DROP TRIGGER IF EXISTS.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.activity (
  id               uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  type             text NOT NULL CHECK (type IN (
                     'item_added', 'item_updated', 'item_removed',
                     'member_joined', 'member_left', 'member_promoted',
                     'list_shared', 'secret_santa_drawn', 'group_updated',
                     'profile_updated')),
  actor_id         uuid NOT NULL REFERENCES public.profiles(user_id) ON DELETE CASCADE,
  group_id         uuid REFERENCES public.groups(id) ON DELETE CASCADE,
  item_id          uuid REFERENCES public.items(id) ON DELETE CASCADE,
  subject_user_id  uuid REFERENCES public.profiles(user_id) ON DELETE CASCADE, -- member who joined / left / was promoted
  audience_user_id uuid REFERENCES public.profiles(user_id) ON DELETE CASCADE, -- set = only this user may see it
  payload          jsonb NOT NULL DEFAULT '{}'::jsonb,                         -- name snapshots, changed fields
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS activity_created_idx  ON public.activity (created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS activity_group_idx    ON public.activity (group_id, created_at DESC);
CREATE INDEX IF NOT EXISTS activity_actor_idx    ON public.activity (actor_id, type, created_at DESC);
CREATE INDEX IF NOT EXISTS activity_item_idx     ON public.activity (item_id);
CREATE INDEX IF NOT EXISTS activity_audience_idx ON public.activity (audience_user_id) WHERE audience_user_id IS NOT NULL;

ALTER TABLE public.activity ENABLE ROW LEVEL SECURITY;  -- intentionally no policies
REVOKE ALL ON public.activity FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- Per-user feed settings (on profiles, like every other setting)
-- ---------------------------------------------------------------------------
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS feed_hidden  text[]      NOT NULL DEFAULT '{}';
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS feed_seen_at timestamptz NOT NULL DEFAULT now();

-- ---------------------------------------------------------------------------
-- log_activity(): the single writer. Optionally coalesces bursts of the same
-- event (e.g. ten quick edits of one item) into one row.
-- Skips silently when the actor is unknown (service role) or when any
-- referenced row is already gone (cascade deletes of accounts / groups / items).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_activity(
  _type     text,
  _actor    uuid,
  _group    uuid DEFAULT NULL,
  _item     uuid DEFAULT NULL,
  _subject  uuid DEFAULT NULL,
  _audience uuid DEFAULT NULL,
  _payload  jsonb DEFAULT '{}'::jsonb,
  _coalesce interval DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  _id uuid;
BEGIN
  IF _actor IS NULL THEN RETURN; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE user_id = _actor) THEN RETURN; END IF;
  IF _group    IS NOT NULL AND NOT EXISTS (SELECT 1 FROM groups   WHERE id      = _group)    THEN RETURN; END IF;
  IF _item     IS NOT NULL AND NOT EXISTS (SELECT 1 FROM items    WHERE id      = _item)     THEN RETURN; END IF;
  IF _subject  IS NOT NULL AND NOT EXISTS (SELECT 1 FROM profiles WHERE user_id = _subject)  THEN RETURN; END IF;
  IF _audience IS NOT NULL AND NOT EXISTS (SELECT 1 FROM profiles WHERE user_id = _audience) THEN RETURN; END IF;

  IF _coalesce IS NOT NULL THEN
    SELECT a.id INTO _id
    FROM activity a
    WHERE a.type = _type
      AND a.actor_id = _actor
      AND a.group_id         IS NOT DISTINCT FROM _group
      AND a.item_id          IS NOT DISTINCT FROM _item
      AND a.subject_user_id  IS NOT DISTINCT FROM _subject
      AND a.audience_user_id IS NOT DISTINCT FROM _audience
      AND a.created_at > now() - _coalesce
    ORDER BY a.created_at DESC
    LIMIT 1;

    IF FOUND THEN
      UPDATE activity a SET
        created_at = now(),
        -- new payload wins, except: union the changed fields and keep the
        -- ORIGINAL old_* values (e.g. old_name) from the first event
        payload = _payload
          || jsonb_build_object('fields', (
               SELECT coalesce(jsonb_agg(DISTINCT f.v), '[]'::jsonb)
               FROM jsonb_array_elements_text(
                      coalesce(a.payload->'fields', '[]'::jsonb) || coalesce(_payload->'fields', '[]'::jsonb)
                    ) AS f(v)))
          || coalesce((SELECT jsonb_object_agg(e.key, e.value)
                       FROM jsonb_each(a.payload) e
                       WHERE e.key LIKE 'old\_%'), '{}'::jsonb)
      WHERE a.id = _id;
      RETURN;
    END IF;
  END IF;

  INSERT INTO activity (type, actor_id, group_id, item_id, subject_user_id, audience_user_id, payload)
  VALUES (_type, _actor, _group, _item, _subject, _audience, coalesce(_payload, '{}'::jsonb));
END;
$$;

-- true when an item_added event for this item was logged in the last 10 minutes
-- (an item that was just created and is still being filled in is not "updated")
CREATE OR REPLACE FUNCTION public.activity_item_is_new(_item uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM activity
    WHERE type = 'item_added' AND item_id = _item AND created_at > now() - interval '10 minutes'
  );
$$;

-- ---------------------------------------------------------------------------
-- Triggers: items
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.activity_items_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  -- shopping_item rows are the owner's private "bought off-list" items
  IF NEW.shopping_item IS NULL THEN
    PERFORM log_activity('item_added', NEW.user_id, NULL, NEW.id, NULL, NULL, '{}'::jsonb, NULL);
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS activity_items_insert ON public.items;
CREATE TRIGGER activity_items_insert AFTER INSERT ON public.items
  FOR EACH ROW EXECUTE FUNCTION public.activity_items_insert();

CREATE OR REPLACE FUNCTION public.activity_items_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  _claimer uuid;
  _fields  text[];
BEGIN
  IF NEW.shopping_item IS NOT NULL THEN RETURN NEW; END IF;

  -- archived / trashed: tell whoever claimed it (and only them)
  IF NOT (OLD.archived OR OLD.deleted) AND (NEW.archived OR NEW.deleted) THEN
    SELECT s.user_id INTO _claimer
    FROM items_status s
    WHERE s.item_id = NEW.id AND s.user_id <> NEW.user_id;
    IF _claimer IS NOT NULL THEN
      PERFORM log_activity('item_removed', NEW.user_id, NULL, NEW.id, NULL, _claimer,
        jsonb_build_object('name', NEW.name,
                           'reason', CASE WHEN NEW.deleted THEN 'deleted' ELSE 'archived' END),
        NULL);
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.archived OR NEW.deleted THEN RETURN NEW; END IF;

  -- real edits only; updated_at changes (claims) are ignored on purpose
  _fields := array_remove(ARRAY[
    CASE WHEN NEW.name          IS DISTINCT FROM OLD.name          THEN 'name'        END,
    CASE WHEN NEW.description   IS DISTINCT FROM OLD.description   THEN 'description' END,
    CASE WHEN NEW.links         IS DISTINCT FROM OLD.links         THEN 'links'       END,
    CASE WHEN NEW.custom_fields IS DISTINCT FROM OLD.custom_fields THEN 'details'     END
  ], NULL);

  IF coalesce(array_length(_fields, 1), 0) > 0 AND NOT activity_item_is_new(NEW.id) THEN
    PERFORM log_activity('item_updated', NEW.user_id, NULL, NEW.id, NULL, NULL,
      jsonb_build_object('fields', to_jsonb(_fields)), interval '30 minutes');
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS activity_items_update ON public.items;
CREATE TRIGGER activity_items_update AFTER UPDATE ON public.items
  FOR EACH ROW EXECUTE FUNCTION public.activity_items_update();

-- hard delete of an item somebody claimed (trash emptied while still claimed)
CREATE OR REPLACE FUNCTION public.activity_items_delete() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  _claimer uuid;
BEGIN
  IF OLD.shopping_item IS NOT NULL OR OLD.archived OR OLD.deleted THEN RETURN OLD; END IF;
  SELECT s.user_id INTO _claimer
  FROM items_status s
  WHERE s.item_id = OLD.id AND s.user_id <> OLD.user_id;
  IF _claimer IS NOT NULL THEN
    -- item_id stays NULL: the row is about to disappear
    PERFORM log_activity('item_removed', OLD.user_id, NULL, NULL, NULL, _claimer,
      jsonb_build_object('name', OLD.name, 'reason', 'deleted'), NULL);
  END IF;
  RETURN OLD;
END;
$$;
DROP TRIGGER IF EXISTS activity_items_delete ON public.items;
CREATE TRIGGER activity_items_delete BEFORE DELETE ON public.items
  FOR EACH ROW EXECUTE FUNCTION public.activity_items_delete();

-- ---------------------------------------------------------------------------
-- Triggers: item_images (adding / removing photos counts as an item edit)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.activity_item_images() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  _item_id uuid := COALESCE(NEW.item_id, OLD.item_id);
  _item    items%ROWTYPE;
BEGIN
  SELECT * INTO _item FROM items WHERE id = _item_id;
  IF NOT FOUND THEN RETURN COALESCE(NEW, OLD); END IF;  -- item itself is being deleted
  IF _item.shopping_item IS NOT NULL OR _item.archived OR _item.deleted THEN RETURN COALESCE(NEW, OLD); END IF;
  IF NOT activity_item_is_new(_item.id) THEN
    PERFORM log_activity('item_updated', _item.user_id, NULL, _item.id, NULL, NULL,
      jsonb_build_object('fields', jsonb_build_array('images')), interval '30 minutes');
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;
DROP TRIGGER IF EXISTS activity_item_images ON public.item_images;
CREATE TRIGGER activity_item_images AFTER INSERT OR DELETE ON public.item_images
  FOR EACH ROW EXECUTE FUNCTION public.activity_item_images();

-- ---------------------------------------------------------------------------
-- Triggers: group_members (joined / left / promoted)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.activity_group_members() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  _creator uuid;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.invite = false THEN
      SELECT created_by INTO _creator FROM groups WHERE id = NEW.group_id;
      -- skip the creator's own owner row added by handle_new_group()
      IF NOT (NEW.owner AND NEW.user_id IS NOT DISTINCT FROM _creator) THEN
        PERFORM log_activity('member_joined', NEW.user_id, NEW.group_id, NULL, NEW.user_id, NULL, '{}'::jsonb, NULL);
      END IF;
    END IF;
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.invite AND NOT NEW.invite THEN
      PERFORM log_activity('member_joined', NEW.user_id, NEW.group_id, NULL, NEW.user_id, NULL, '{}'::jsonb, NULL);
    END IF;
    IF NOT OLD.owner AND NEW.owner AND NOT NEW.invite THEN
      PERFORM log_activity('member_promoted', auth.uid(), NEW.group_id, NULL, NEW.user_id, NULL, '{}'::jsonb, NULL);
    END IF;
    RETURN NEW;

  ELSE -- DELETE (also fires for cascades; log_activity skips when the group/profile is gone)
    IF NOT OLD.invite THEN
      PERFORM log_activity('member_left', COALESCE(auth.uid(), OLD.user_id), OLD.group_id, NULL, OLD.user_id, NULL,
        jsonb_build_object('removed', auth.uid() IS NOT NULL AND auth.uid() <> OLD.user_id), NULL);
    END IF;
    RETURN OLD;
  END IF;
END;
$$;
DROP TRIGGER IF EXISTS activity_group_members ON public.group_members;
CREATE TRIGGER activity_group_members AFTER INSERT OR UPDATE OR DELETE ON public.group_members
  FOR EACH ROW EXECUTE FUNCTION public.activity_group_members();

-- ---------------------------------------------------------------------------
-- Triggers: lists_groups (a list was shared to a group)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.activity_lists_groups() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  _list lists%ROWTYPE;
BEGIN
  -- lists linked automatically while joining a group are not "news"
  IF EXISTS (
    SELECT 1 FROM activity
    WHERE type = 'member_joined' AND actor_id = NEW.user_id AND group_id = NEW.group_id
      AND created_at > now() - interval '10 minutes'
  ) THEN
    RETURN NEW;
  END IF;
  SELECT * INTO _list FROM lists WHERE id = NEW.list_id AND user_id = NEW.user_id;
  PERFORM log_activity('list_shared', NEW.user_id, NEW.group_id, NULL, NULL, NULL,
    jsonb_build_object('list_id', NEW.list_id, 'list_name', _list.name, 'child_list', COALESCE(_list.child_list, false)),
    NULL);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS activity_lists_groups ON public.lists_groups;
CREATE TRIGGER activity_lists_groups AFTER INSERT ON public.lists_groups
  FOR EACH ROW EXECUTE FUNCTION public.activity_lists_groups();

-- ---------------------------------------------------------------------------
-- Triggers: groups (Secret Santa drawn, name / image changed)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.activity_groups_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  _fields text[];
BEGIN
  -- Secret Santa drawn (or redrawn). Only name/date are copied - NEVER the drawing.
  IF (NEW.secret_santa->>'status') = 'on'
     AND ( (OLD.secret_santa->>'status') IS DISTINCT FROM 'on'
           OR (NEW.secret_santa->'drawing') IS DISTINCT FROM (OLD.secret_santa->'drawing') ) THEN
    PERFORM log_activity('secret_santa_drawn', auth.uid(), NEW.id, NULL, NULL, NULL,
      jsonb_build_object('name', NEW.secret_santa->>'name',
                         'date', NEW.secret_santa->>'date',
                         'redraw', (OLD.secret_santa->>'status') = 'on'),
      NULL);
  END IF;

  _fields := array_remove(ARRAY[
    CASE WHEN NEW.name        IS DISTINCT FROM OLD.name        THEN 'name'  END,
    CASE WHEN NEW.image_token IS DISTINCT FROM OLD.image_token THEN 'image' END
  ], NULL);
  IF coalesce(array_length(_fields, 1), 0) > 0 THEN
    PERFORM log_activity('group_updated', auth.uid(), NEW.id, NULL, NULL, NULL,
      jsonb_strip_nulls(jsonb_build_object(
        'fields',   to_jsonb(_fields),
        'old_name', CASE WHEN NEW.name IS DISTINCT FROM OLD.name THEN OLD.name END,
        'new_name', CASE WHEN NEW.name IS DISTINCT FROM OLD.name THEN NEW.name END)),
      interval '30 minutes');
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS activity_groups_update ON public.groups;
CREATE TRIGGER activity_groups_update AFTER UPDATE ON public.groups
  FOR EACH ROW EXECUTE FUNCTION public.activity_groups_update();

-- ---------------------------------------------------------------------------
-- Triggers: profiles (new photo / bio)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.activity_profiles_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  _fields text[];
BEGIN
  _fields := array_remove(ARRAY[
    CASE WHEN NEW.bio IS DISTINCT FROM OLD.bio AND coalesce(NEW.bio, '') <> '' THEN 'bio' END,
    CASE WHEN NEW.avatar_token IS DISTINCT FROM OLD.avatar_token
              AND NEW.avatar_token IS NOT NULL AND NEW.avatar_token <> -1 THEN 'avatar' END
  ], NULL);
  IF coalesce(array_length(_fields, 1), 0) > 0 THEN
    PERFORM log_activity('profile_updated', NEW.user_id, NULL, NULL, NULL, NULL,
      jsonb_build_object('fields', to_jsonb(_fields)), interval '30 minutes');
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS activity_profiles_update ON public.profiles;
CREATE TRIGGER activity_profiles_update AFTER UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.activity_profiles_update();

-- ---------------------------------------------------------------------------
-- feed_events: everything the CURRENT user (auth.uid()) may see.
-- A plain view (not a function) so ORDER BY / LIMIT / WHERE from get_feed()
-- push down and the (created_at, id) index can stop early. It runs with the
-- owner's rights; clients cannot select from it directly (see REVOKE below).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.feed_events AS
SELECT f.*
FROM (
  SELECT
    a.id, a.type, a.created_at, a.payload,
    a.actor_id, a.group_id, a.item_id, a.subject_user_id,
    vis.gids    AS group_ids,
    cl.claimed  AS claimed_by_me,
    CASE a.type
      WHEN 'item_added'         THEN 'items_new'
      WHEN 'item_updated'       THEN CASE WHEN cl.claimed THEN 'items_claimed' ELSE 'items_updated' END
      WHEN 'item_removed'       THEN 'items_claimed'
      WHEN 'member_joined'      THEN 'group_members'
      WHEN 'member_left'        THEN 'group_members'
      WHEN 'member_promoted'    THEN 'group_members'
      WHEN 'list_shared'        THEN 'group_lists'
      WHEN 'secret_santa_drawn' THEN 'secret_santa'
      WHEN 'group_updated'      THEN 'group_updated'
      WHEN 'profile_updated'    THEN 'profile_updated'
    END AS category,
    -- visibility
    (
      (a.type IN ('item_added', 'item_updated')
        AND i.id IS NOT NULL AND NOT i.archived AND NOT i.deleted AND i.shopping_item IS NULL
        AND cardinality(vis.gids) > 0)
      OR (a.type = 'item_removed' AND a.audience_user_id = auth.uid())
      OR (a.type IN ('member_joined', 'member_left', 'member_promoted', 'list_shared', 'secret_santa_drawn', 'group_updated')
        AND EXISTS (
          SELECT 1 FROM group_members me
          WHERE me.group_id = a.group_id AND me.user_id = auth.uid() AND me.invite = false
            AND a.created_at >= me.created_at))
      OR (a.type = 'profile_updated'
        AND EXISTS (
          SELECT 1 FROM group_members me
          JOIN group_members them ON them.group_id = me.group_id AND them.user_id = a.actor_id AND them.invite = false
          WHERE me.user_id = auth.uid() AND me.invite = false))
    ) AS visible
  FROM activity a
  LEFT JOIN items i ON i.id = a.item_id
  CROSS JOIN LATERAL (
    SELECT EXISTS (
      SELECT 1 FROM items_status s WHERE s.item_id = a.item_id AND s.user_id = auth.uid()
    ) AS claimed
  ) cl
  CROSS JOIN LATERAL (
    -- groups where viewer and item owner are both accepted members AND the item is shared there
    SELECT COALESCE(array_agg(DISTINCT mg.group_id), '{}'::uuid[]) AS gids
    FROM group_members mg
    JOIN group_members og ON og.group_id = mg.group_id AND og.user_id = i.user_id AND og.invite = false
    WHERE a.item_id IS NOT NULL
      AND mg.user_id = auth.uid() AND mg.invite = false
      AND (
        EXISTS (SELECT 1 FROM profiles p WHERE p.user_id = i.user_id AND p.enable_lists = false)
        OR EXISTS (
          SELECT 1 FROM items_lists il
          JOIN lists_groups lg ON lg.list_id = il.list_id AND lg.user_id = il.user_id
          WHERE il.item_id = i.id AND lg.group_id = mg.group_id)
      )
  ) vis
  WHERE a.actor_id <> auth.uid()
    AND (a.audience_user_id IS NULL OR a.audience_user_id = auth.uid())
) f
WHERE f.visible
  AND f.category <> ALL (
    COALESCE((SELECT p.feed_hidden FROM profiles p WHERE p.user_id = auth.uid()), '{}'::text[])
  );

REVOKE ALL ON public.feed_events FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_feed(
  _before    timestamptz DEFAULT NULL,
  _before_id uuid        DEFAULT NULL,
  _limit     int         DEFAULT 30
) RETURNS TABLE (
  id uuid, type text, category text, created_at timestamptz, payload jsonb,
  group_ids uuid[], claimed_by_me boolean,
  actor jsonb, "group" jsonb, item jsonb, subject jsonb
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    f.id, f.type, f.category, f.created_at, f.payload, f.group_ids, f.claimed_by_me,
    (SELECT jsonb_build_object('user_id', p.user_id, 'first_name', p.first_name,
                               'last_name', p.last_name, 'avatar_token', p.avatar_token)
       FROM profiles p WHERE p.user_id = f.actor_id) AS actor,
    (SELECT jsonb_build_object('id', g.id, 'name', g.name, 'image_token', g.image_token)
       FROM groups g WHERE g.id = COALESCE(
         f.group_id,
         f.group_ids[1],
         -- profile events have no group of their own: use one the viewer shares with the actor (for linking)
         CASE WHEN f.type = 'profile_updated' THEN (
           SELECT me.group_id FROM group_members me
           JOIN group_members them ON them.group_id = me.group_id AND them.user_id = f.actor_id AND them.invite = false
           WHERE me.user_id = auth.uid() AND me.invite = false
           ORDER BY me.created_at LIMIT 1)
         END)) AS "group",
    (SELECT jsonb_build_object(
              'id', i.id, 'name', i.name, 'user_id', i.user_id,
              'first_image_id', (SELECT ii.id FROM item_images ii WHERE ii.item_id = i.id
                                 ORDER BY ii.position, ii.created_at LIMIT 1),
              'child_list_id', (SELECT il.list_id FROM items_lists il
                                JOIN lists l ON l.id = il.list_id AND l.user_id = il.user_id
                                WHERE il.item_id = i.id AND l.child_list LIMIT 1))
       FROM items i WHERE i.id = f.item_id) AS item,
    (SELECT jsonb_build_object('user_id', p.user_id, 'first_name', p.first_name, 'last_name', p.last_name)
       FROM profiles p WHERE p.user_id = f.subject_user_id) AS subject
  FROM feed_events f
  WHERE _before IS NULL
     OR (f.created_at, f.id) < (_before, COALESCE(_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
  ORDER BY f.created_at DESC, f.id DESC
  LIMIT LEAST(GREATEST(COALESCE(_limit, 30), 1), 100);
$$;

CREATE OR REPLACE FUNCTION public.get_feed_unread_count() RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT count(*)::int FROM (
    SELECT 1 FROM feed_events f
    WHERE f.created_at > (SELECT p.feed_seen_at FROM profiles p WHERE p.user_id = auth.uid())
    LIMIT 99
  ) x;
$$;

-- ---------------------------------------------------------------------------
-- Privileges: internal helpers/triggers are not callable by clients
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.log_activity(text, uuid, uuid, uuid, uuid, uuid, jsonb, interval) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.activity_item_is_new(uuid)   FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.activity_items_insert()      FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.activity_items_update()      FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.activity_items_delete()      FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.activity_item_images()       FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.activity_group_members()     FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.activity_lists_groups()      FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.activity_groups_update()     FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.activity_profiles_update()   FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.get_feed(timestamptz, uuid, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_feed(timestamptz, uuid, int) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_feed_unread_count()          FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_feed_unread_count()          TO authenticated;
