--
-- Notifications table
CREATE TABLE IF NOT EXISTS public.notifications
(
	id uuid NOT NULL DEFAULT uuid_generate_v4() PRIMARY KEY,
	user_id uuid NOT NULL,
	title text NOT NULL,
	body text NOT NULL,
	seen boolean NOT NULL DEFAULT false,
	icon text,
	action text,
	created_at timestamp with time zone DEFAULT now(),
	
	
	CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id)
		REFERENCES public.profiles (user_id) MATCH SIMPLE
		ON UPDATE NO ACTION
		ON DELETE CASCADE
);

-- Set up Realtime
alter publication supabase_realtime add table notifications;


-- Set up Security
alter table notifications enable row level security;

create policy "Any one can view notifications"
  on notifications for select
  TO authenticated 
  using ( auth.uid() = user_id );

create policy "Users can update own notifications"
  on notifications for update
  TO authenticated 
  using ( auth.uid() = user_id );

create policy "Users can delete notifications"
  on notifications for delete
  TO authenticated 
  using ( auth.uid() = user_id );