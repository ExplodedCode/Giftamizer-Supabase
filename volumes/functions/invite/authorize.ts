// Access checks for the routes that send email. `supabase` is the service role
// client (bypasses RLS), so every check here has to be explicit.

export class HttpError extends Error {
	constructor(public status: number, message: string) {
		super(message);
	}
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const requireUuid = (value: unknown, name: string): string => {
	if (typeof value !== 'string' || !UUID.test(value)) throw new HttpError(400, `Invalid ${name}`);
	return value;
};

export const fullName = (profile: { first_name: string; last_name: string }) => `${profile.first_name} ${profile.last_name}`.trim();

// Resolves the caller from their access token and requires them to be an
// (accepted) owner of the group.
export const authorizeGroupOwner = async (supabase: any, request: any, rawGroupId: unknown) => {
	const token = request.headers.get('authorization')?.match(/^Bearer (.+)$/i)?.[1];
	if (!token) throw new HttpError(401, 'Unauthorized');

	// Also rejects the anon key, which is a valid JWT but has no user.
	const { data: auth, error: authError } = await supabase.auth.getUser(token);
	if (authError || !auth?.user) throw new HttpError(401, 'Unauthorized');

	const groupId = requireUuid(rawGroupId, 'group id');
	const caller = await getMember(supabase, groupId, auth.user.id);
	if (!caller.owner || caller.invite) throw new HttpError(403, 'Forbidden');

	const { data: group, error } = await supabase.from('groups').select('id, name, secret_santa').eq('id', groupId).single();
	if (error) throw error;

	return { group, callerId: caller.user_id as string, invitedBy: fullName(caller.profile) };
};

// A group member with their profile; 403 if they aren't in the group.
export const getMember = async (supabase: any, groupId: string, rawUserId: unknown) => {
	const userId = requireUuid(rawUserId, 'user id');

	const { data: member, error } = await supabase
		.from('group_members')
		.select('user_id, owner, invite, profile:profiles(email, first_name, last_name, email_invites)')
		.eq('group_id', groupId)
		.eq('user_id', userId)
		.maybeSingle();
	if (error) throw error;
	if (!member?.profile) throw new HttpError(403, 'Forbidden');

	return member;
};

// The address from a pending external invite; 403 if there isn't one.
export const getExternalInviteEmail = async (supabase: any, groupId: string, rawEmail: unknown): Promise<string> => {
	if (typeof rawEmail !== 'string' || !rawEmail) throw new HttpError(400, 'Invalid email');

	const { data: invite, error } = await supabase.from('external_invites').select('email').eq('group_id', groupId).eq('email', rawEmail).maybeSingle();
	if (error) throw error;
	if (!invite) throw new HttpError(403, 'No pending invite for this email');

	// The column has no format constraint, so make sure it's a single address.
	if (!/^[^\s@<>,;:"()]+@[^\s@<>,;:"()]+$/.test(invite.email)) throw new HttpError(400, 'Invalid email');

	return invite.email;
};
