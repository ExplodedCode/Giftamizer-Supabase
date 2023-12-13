-- set file owners null on user delete
alter table storage.objects
drop constraint objects_owner_fkey,
add constraint objects_owner_fkey
   foreign key (owner)
   references auth.users(id)
   on delete set null;

-- clear realtime
begin;
  drop publication if exists supabase_realtime;
  create publication supabase_realtime;
commit;

