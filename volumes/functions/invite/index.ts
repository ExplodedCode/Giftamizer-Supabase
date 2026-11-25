import { Application, Router } from 'https://deno.land/x/oak@v12.6.1/mod.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.33.1';

import template from './template.ts';
import { sendLimitedEmail } from './limit.ts';
import { authorizeGroupOwner, fullName, getExternalInviteEmail, getMember, HttpError } from './authorize.ts';

import { internal, external, secretSanta } from './emails.js';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const supabase = createClient(SUPABASE_URL || '', SUPABASE_SERVICE_ROLE_KEY || '');

const readBody = async (context: any) => {
	try {
		// Note: request body will be streamed to the function as chunks, set limit to 0 to fully read it.
		return await context.request.body({ type: 'json', limit: 0 }).value;
	} catch {
		throw new HttpError(400, 'Invalid request body');
	}
};

const handleError = (context: any, error: unknown) => {
	if (error instanceof HttpError) {
		context.response.status = error.status;
		context.response.body = { message: error.message };
		return;
	}

	// Don't return SMTP / database details to the caller.
	console.error(error);
	context.response.status = 500;
	context.response.body = { message: 'Unable to send invite' };
};

const router = new Router();
router
	.post('/invite/preview', async (context) => {
		// Unauthenticated preview for a group invite link (GroupInvite.tsx).
		// Uses the service role to sign the group/member images server-side,
		// since the visitor may not be signed in yet and storage.objects RLS
		// requires an authenticated session. get_link_invite() itself still
		// gates this on the group having invite_link = true.
		try {
			const result = context.request.body({ type: 'json', limit: 0 });
			const body = await result.value;
			const group_id = body.group_id;

			const { data, error } = await supabase.rpc('get_link_invite', { _group_id: group_id }).single();
			if (error) {
				context.response.status = 400;
				context.response.body = { message: error.message };
				return;
			}

			const image = data.image_token ? (await supabase.storage.from('groups').createSignedUrl(`${group_id}`, 3600)).data?.signedUrl : undefined;

			const members = await Promise.all(
				(data.members || []).map(async (member: any) => ({
					...member,
					image: member.avatar_token ? (await supabase.storage.from('avatars').createSignedUrl(`${member.user_id}`, 3600)).data?.signedUrl : undefined,
				}))
			);

			context.response.body = { name: data.name, image_token: data.image_token, image, members };
		} catch (error) {
			console.log(error);
			context.response.status = 500;
			context.response.body = { message: error.message };
		}
	})
	// The three routes below send email from our domain, so the request body is
	// only trusted for *ids*: the caller must be a signed-in owner of the group,
	// the recipient must really have been invited to it, and every name/address
	// used in the email comes from the database (see authorize.ts). Sending is
	// rate limited (see limit.ts).
	.post('/invite/internal', async (context) => {
		try {
			const body = await readBody(context);
			const { group, callerId, invitedBy } = await authorizeGroupOwner(supabase, context.request, body?.group?.id);
			const recipient = await getMember(supabase, group.id, body?.user?.user_id);
			if (!recipient.invite) throw new HttpError(403, 'User has no pending invite');

			if (recipient.profile.email_invites) {
				const html = template(internal, { full_name: fullName(recipient.profile), invited_by: invitedBy, group_name: group.name });

				const res = await sendLimitedEmail(supabase, callerId, {
					to: recipient.profile.email,
					subject: 'Giftamizer Invite',
					body: html,
				});
				console.log('Send internal invite: ', res);
			}

			context.response.body = 'ok';
		} catch (error) {
			handleError(context, error);
		}
	})
	.post('/invite/external', async (context) => {
		try {
			const body = await readBody(context);
			const { group, callerId, invitedBy } = await authorizeGroupOwner(supabase, context.request, body?.group?.id);
			const email = await getExternalInviteEmail(supabase, group.id, body?.user?.email);

			const html = template(external, { invited_by: invitedBy, group_name: group.name });

			const res = await sendLimitedEmail(supabase, callerId, {
				to: email,
				subject: 'Welcome to Giftamizer!',
				body: html,
			});
			console.log('Send external invite: ', res);

			context.response.body = 'ok';
		} catch (error) {
			handleError(context, error);
		}
	})
	.post('/invite/secret-santa', async (context) => {
		try {
			const body = await readBody(context);
			const { group, callerId, invitedBy } = await authorizeGroupOwner(supabase, context.request, body?.group?.id);
			const recipient = await getMember(supabase, group.id, body?.user?.user_id);
			const drawing = group.secret_santa?.drawing ?? {};
			if (group.secret_santa?.status !== 'on' || !Object.hasOwn(drawing, recipient.user_id)) {
				throw new HttpError(403, 'User is not in an active Secret Santa');
			}

			// send in app notification
			const { error: notificationError } = await supabase.from('notifications').insert([
				{
					user_id: recipient.user_id,
					title: `${group.name} Secret Santa`,
					body: 'You have been added to a Secret Santa!',
					icon: 'gift',
					action: `openGroup_${group.id}`,
				},
			]);
			if (notificationError) console.log('Secret santa notification error: ', notificationError);

			// send email
			if (recipient.profile.email_invites) {
				const html = template(secretSanta, { full_name: fullName(recipient.profile), invited_by: invitedBy, group_name: group.name, group_id: group.id });

				const res = await sendLimitedEmail(supabase, callerId, {
					to: recipient.profile.email,
					subject: 'Secret Santa',
					body: html,
				});
				console.log('Send secret santa invite: ', res);
			}

			context.response.body = 'ok';
		} catch (error) {
			handleError(context, error);
		}
	});

const app = new Application();
app.use(router.routes());
app.use(router.allowedMethods());

await app.listen({ port: 8000 });
