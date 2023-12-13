CREATE TABLE items (
  id UUID DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  links TEXT[] null,
  domains text[] null,
  custom_fields jsonb null,
  archived boolean not null default false,
  deleted boolean not null default false,
  shopping_item uuid null,
  image_token numeric,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  constraint items_pkey primary key (id),
  constraint items_user_id_fkey foreign key (user_id) references profiles (user_id) on delete cascade,
  constraint items_shopping_item_fkey foreign key (shopping_item) references profiles (user_id)
);
create trigger handle_updated_at before update on items
  for each row execute procedure moddatetime (updated_at);

  -- Set up Storage
insert into storage.buckets (id, name) values ('items', 'items');
CREATE OR REPLACE FUNCTION is_item_owner(
    _item_id UUID,
    _user_id UUID
) RETURNS BOOLEAN AS
$$
SELECT(
  exists(
   SELECT 1 FROM items WHERE items.id = _item_id and items.user_id = _user_id
  )
)
$$ LANGUAGE SQL SECURITY DEFINER;
CREATE POLICY "allow item image select"
  ON storage.objects
  AS PERMISSIVE
  FOR SELECT
  TO authenticated 
  USING (
    (bucket_id = 'items'::text)	AND is_item_owner(Cast(storage.filename(name) as uuid), auth.uid())
  );
CREATE POLICY "allow item image insert"
  ON storage.objects
  AS PERMISSIVE
  FOR INSERT
  TO authenticated 
  WITH CHECK (
    (bucket_id = 'items'::text)	AND is_item_owner(Cast(storage.filename(name) as uuid), auth.uid())
  );
CREATE POLICY "allow item image update"
  ON storage.objects
  AS PERMISSIVE
  FOR UPDATE
  TO authenticated 
  USING (
    (bucket_id = 'items'::text)	AND is_item_owner(Cast(storage.filename(name) as uuid), auth.uid())
  );
CREATE POLICY "allow item image delete"
  ON storage.objects
  AS PERMISSIVE
  FOR DELETE
  TO authenticated 
  USING (
    (bucket_id = 'items'::text)	AND is_item_owner(Cast(storage.filename(name) as uuid), auth.uid())
  );

CREATE TABLE lists (
  id TEXT DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES profiles(user_id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  child_list boolean NOT NULL DEFAULT false,
  bio text,
  pinned boolean not null default false,
  avatar_token numeric,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  PRIMARY KEY (id, user_id)
);

CREATE OR REPLACE FUNCTION is_list_child(
    _list_id text
) RETURNS BOOLEAN AS
$$
SELECT(
   SELECT child_list FROM lists WHERE lists.id = _list_id
)
$$ LANGUAGE SQL SECURITY DEFINER;

-- Set up Storage
insert into storage.buckets (id, name) values ('lists', 'lists');
CREATE OR REPLACE FUNCTION is_list_owner(
    _list_id TEXT,
    _user_id UUID
) RETURNS BOOLEAN AS
$$
SELECT(
  exists(
    SELECT 1 FROM lists WHERE lists.id = _list_id and lists.user_id = _user_id
  )
)
$$ LANGUAGE SQL SECURITY DEFINER;
CREATE POLICY "allow list image select"
  ON storage.objects
  AS PERMISSIVE
  FOR SELECT
  TO authenticated 
  USING (
    (bucket_id = 'lists'::text)	AND is_list_owner(Cast(storage.filename(name) as TEXT), auth.uid())
  );
CREATE POLICY "allow list image insert"
  ON storage.objects
  AS PERMISSIVE
  FOR INSERT
  TO authenticated 
  WITH CHECK (
    (bucket_id = 'lists'::text)	AND is_list_owner(Cast(storage.filename(name) as TEXT), auth.uid())
  );
CREATE POLICY "allow list image update"
  ON storage.objects
  AS PERMISSIVE
  FOR UPDATE
  TO authenticated 
  USING (
    (bucket_id = 'lists'::text)	AND is_list_owner(Cast(storage.filename(name) as TEXT), auth.uid())
  );
CREATE POLICY "allow list image delete"
  ON storage.objects
  AS PERMISSIVE
  FOR DELETE
  TO authenticated 
  USING (
    (bucket_id = 'lists'::text)	AND is_list_owner(Cast(storage.filename(name) as TEXT), auth.uid())
  );

CREATE TABLE items_lists (
  item_id UUID REFERENCES items(id) ON DELETE CASCADE,
  list_id TEXT,
  user_id UUID,
  
  PRIMARY KEY (item_id, list_id, user_id),
  
  FOREIGN KEY (list_id, user_id) 
    REFERENCES lists(id, user_id)
    ON DELETE CASCADE
);
CREATE TABLE lists_groups (
  list_id TEXT,
  group_id UUID,
  user_id UUID,
  
  PRIMARY KEY (list_id, group_id, user_id),

  FOREIGN KEY (list_id, user_id) 
    REFERENCES lists(id, user_id)
    ON DELETE CASCADE,

  FOREIGN KEY (group_id)
    REFERENCES groups(id) 
    ON DELETE CASCADE
);

--
-- items
alter table items enable row level security;
alter publication supabase_realtime add table items;

create policy "Users can view own items"
  ON items for select
  TO authenticated 
  using (user_id = auth.uid());
create policy "Users can add own items"
  ON items for insert
  TO authenticated 
  with check (user_id = auth.uid());
create policy "Users can update own items"
  ON items for update
  TO authenticated 
  using (user_id = auth.uid());
create policy "Users can delete own items"
  ON items for delete
  TO authenticated 
  using (user_id = auth.uid());
-- Allow group members to select items
CREATE POLICY "Group members can select items"
  ON items for select
  TO authenticated 
  USING (
    EXISTS (
      SELECT 1
      FROM profiles
      WHERE
        profiles.user_id = items.user_id
        AND profiles.enable_lists = false
    ) OR (
      EXISTS (
        SELECT 1 
        FROM group_members
        JOIN lists_groups ON lists_groups.group_id = group_members.group_id
        JOIN items_lists ON items_lists.list_id = lists_groups.list_id
        WHERE 
          group_members.user_id = auth.uid() 
          AND items_lists.item_id = items.id
      )
    )
  );


--
-- lists
alter table lists enable row level security;
alter publication supabase_realtime add table lists;

create policy "Users can view own lists"
  ON lists for select
  TO authenticated 
  using (user_id = auth.uid());
create policy "Users can add own lists"
  ON lists for insert
  TO authenticated 
  with check (user_id = auth.uid());
create policy "Users can update own lists"
  ON lists for update
  TO authenticated 
  using (user_id = auth.uid());
create policy "Users can delete own lists"
  ON lists for delete
  TO authenticated 
  using (user_id = auth.uid());
-- Allow group members to select lists
CREATE POLICY "Group members can select lists"
  ON lists for select
  USING (
    EXISTS (
      SELECT 1
      FROM group_members
      JOIN lists_groups ON lists_groups.group_id = group_members.group_id 
      WHERE 
        group_members.user_id = auth.uid()
        AND lists_groups.list_id = lists.id
    )
  );


--
-- items_lists
alter table items_lists enable row level security;
alter publication supabase_realtime add table items_lists;

create policy "Users can view own items_lists"
  on items_lists for select
  TO authenticated 
  using (user_id = auth.uid());
create policy "Users can add own items_lists"
  on items_lists for insert
  TO authenticated 
  with check (user_id = auth.uid());
create policy "Users can update own items_lists"
  on items_lists for update
  TO authenticated 
  using (user_id = auth.uid());
create policy "Users can delete own items_lists"
  on items_lists for delete
  TO authenticated 
  using (user_id = auth.uid());
-- Allow group members to select items_lists
CREATE POLICY "Group members can select items_lists"
  ON items_lists for select
  TO authenticated 
  USING (
    EXISTS (
      SELECT 1 
      FROM group_members
      JOIN lists_groups ON lists_groups.group_id = group_members.group_id
      WHERE 
        group_members.user_id = auth.uid() 
        AND lists_groups.list_id = items_lists.list_id
    )
  );


--
-- lists_groups
alter table lists_groups enable row level security;
alter publication supabase_realtime add table lists_groups;

create policy "Users can view own lists_groups"
  on lists_groups for select
  TO authenticated 
  using (user_id = auth.uid());
create policy "Users can add own lists_groups"
  on lists_groups for insert
  TO authenticated 
  with check (user_id = auth.uid()); 
create policy "Users can update own lists_groups"
  on lists_groups for update
  TO authenticated 
  using (user_id = auth.uid());
create policy "Users or group owners can delete own lists_groups"
  on lists_groups for delete
  TO authenticated 
  using (user_id = auth.uid() OR (is_group_owner(group_id, auth.uid()) AND is_list_child(list_id)));
-- Allow group members to select lists_groups
CREATE POLICY "Group members can select lists_groups"
  ON lists_groups for select
  TO authenticated 
  USING (
    EXISTS (
      SELECT 1 
      FROM group_members
      WHERE 
        group_members.user_id = auth.uid() 
        AND group_members.group_id = lists_groups.group_id
    )
  );


--
-- link domains
create table link_domains (
  original text not null,
  domain text not null,
  constraint link_domains_pkey primary key (original)
);


CREATE FUNCTION public.get_link_domains() RETURNS trigger
  LANGUAGE plpgsql AS $$
DECLARE
  domains text[];
  links text[] := NEW.links;
BEGIN
  IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') AND array_length(links, 1) is not null  THEN

    FOR i IN 1 .. array_upper(links, 1) LOOP
      domains := domains || (
        SELECT CASE WHEN link_domains.domain is null THEN replace(token, 'www.', '') ELSE link_domains.domain END as domain FROM ts_debug(links[i])
        LEFT JOIN public.link_domains on replace(token, 'www.', '') = original
        WHERE alias = 'host' limit 1
      );
    end loop;
  END IF;

  NEW.domains = domains;
  RETURN NEW;
END;
$$;

CREATE TRIGGER update_item_domains 
BEFORE INSERT OR UPDATE ON public.items 
FOR EACH ROW 
EXECUTE FUNCTION public.get_link_domains();