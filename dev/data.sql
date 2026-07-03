-- Local dev seed data.
--
-- The Giftamizer schema (profiles, groups, items, lists, etc.) is created by
-- volumes/db/giftamizer/*.sql, which runs before this file on first boot.
-- Add INSERT statements here if you want sample data preloaded into a fresh
-- local database. Sign up through the app/Studio to exercise the real
-- auth.users -> public.profiles flow instead of hand-inserting profile rows.

-- The frontend queries public.system with .single() on every page load (see
-- Giftamizer/src/lib/useSupabase/hooks/useSystem.tsx) - an empty table 406s
-- app-wide, so a fresh install needs exactly one row here.
INSERT INTO public.system (maintenance) VALUES (false);
