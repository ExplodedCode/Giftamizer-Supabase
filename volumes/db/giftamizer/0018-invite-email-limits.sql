-- Rate limiting for the emails sent by the `invite` edge function (group and
-- Secret Santa invites). Safe to re-run.
--
-- One row per email sent in the last 24 hours; older rows are pruned on the
-- next send. sender_id deliberately has no foreign key: deleting an account
-- must not give back the emails it already sent.
CREATE TABLE IF NOT EXISTS public.invite_email_log
(
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  sender_id uuid NOT NULL,
  recipient text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Only the edge function (service role) may use this.
ALTER TABLE public.invite_email_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.invite_email_log FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON public.invite_email_log TO service_role;

-- Reserves one email if every limit allows it.
-- Returns {"id": ...} when reserved, or {"limited_by": "sender"|"recipient"|"total"}.
-- Delete the row again (by id) if the email couldn't be sent.
CREATE OR REPLACE FUNCTION public.reserve_invite_email(
    _sender_id uuid,
    _recipient text,
    _sender_limit int,
    _recipient_limit int,
    _total_limit int
) RETURNS jsonb
    LANGUAGE plpgsql SET search_path = public
    AS $$
DECLARE
  _email text := lower(trim(_recipient));
  _sender_count int;
  _recipient_count int;
  _total_count int;
  _id uuid;
BEGIN
  -- One reservation at a time, so parallel requests can't exceed a limit.
  PERFORM pg_advisory_xact_lock(hashtext('reserve_invite_email'));

  -- clock_timestamp(): now() is when the transaction began, which may be
  -- before it had to wait for the lock.
  DELETE FROM invite_email_log WHERE created_at < clock_timestamp() - interval '24 hours';

  SELECT count(*) FILTER (WHERE sender_id = _sender_id), count(*) FILTER (WHERE recipient = _email), count(*)
  INTO _sender_count, _recipient_count, _total_count
  FROM invite_email_log;

  -- COALESCE: a missing limit blocks instead of meaning "unlimited".
  IF _sender_count >= COALESCE(_sender_limit, 0) THEN
    RETURN jsonb_build_object('limited_by', 'sender');
  ELSIF _recipient_count >= COALESCE(_recipient_limit, 0) THEN
    RETURN jsonb_build_object('limited_by', 'recipient');
  ELSIF _total_count >= COALESCE(_total_limit, 0) THEN
    RETURN jsonb_build_object('limited_by', 'total');
  END IF;

  INSERT INTO invite_email_log (sender_id, recipient, created_at)
  VALUES (_sender_id, _email, clock_timestamp())
  RETURNING id INTO _id;

  RETURN jsonb_build_object('id', _id);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.reserve_invite_email(uuid, text, int, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_invite_email(uuid, text, int, int, int) TO service_role;
