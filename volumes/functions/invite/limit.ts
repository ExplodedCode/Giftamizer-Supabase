import { HttpError } from './authorize.ts';
import { type Email, sendEmail } from './email.ts';

const limitFromEnv = (name: string, fallback: number) => {
	const value = Deno.env.get(name)?.trim();
	return value && /^\d{1,9}$/.test(value) ? Number(value) : fallback;
};

// All limits cover a rolling 24 hours (see 0018-invite-email-limits.sql).
const SENDER_LIMIT = limitFromEnv('INVITE_EMAIL_SENDER_LIMIT', 50);
const RECIPIENT_LIMIT = limitFromEnv('INVITE_EMAIL_RECIPIENT_LIMIT', 5);
const TOTAL_LIMIT = limitFromEnv('INVITE_EMAIL_TOTAL_LIMIT', 200);

const LIMIT_MESSAGES: Record<string, string> = {
	sender: 'You have reached your daily invite email limit.',
	recipient: 'The daily invite email limit per person has been reached.',
	total: 'The daily invite email limit has been reached.',
};

// Sends an email on behalf of a user, or throws a 429 if a limit is reached.
// `supabase` is the service role client.
export const sendLimitedEmail = async (supabase: any, senderId: string, email: Email): Promise<string> => {
	const { data, error } = await supabase.rpc('reserve_invite_email', {
		_sender_id: senderId,
		_recipient: email.to,
		_sender_limit: SENDER_LIMIT,
		_recipient_limit: RECIPIENT_LIMIT,
		_total_limit: TOTAL_LIMIT,
	});
	// Also fails closed if the migration hasn't been applied.
	if (error) throw error;
	if (!data?.id) {
		console.warn(`Invite email limit reached (${data?.limited_by}), sender ${senderId}`);
		throw new HttpError(429, LIMIT_MESSAGES[data?.limited_by] ?? LIMIT_MESSAGES.total);
	}

	try {
		return await sendEmail(email);
	} catch (sendError) {
		// Nothing was delivered, so don't count it.
		const { error: releaseError } = await supabase.from('invite_email_log').delete().eq('id', data.id);
		if (releaseError) console.error('Unable to release invite email: ', releaseError);
		throw sendError;
	}
};
