import { Application, Router } from 'https://deno.land/x/oak@v12.6.1/mod.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.33.1';

import template from './template.ts';
import { getToken, sendEmail } from './graph.ts';

import { internal, external, secretSanta } from './emails.js';
import { stringToBoolean } from './utils.ts';

const DEV_MODE = stringToBoolean(Deno.env.get('DEV_MODE'));
const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const supabase = createClient(SUPABASE_URL || '', SUPABASE_SERVICE_ROLE_KEY || '');

const router = new Router();
router
	.post('/invite/internal', async (context) => {
		try {
			// Note: request body will be streamed to the function as chunks, set limit to 0 to fully read it.
			const result = context.request.body({ type: 'json', limit: 0 });
			const body = await result.value;
			const group = body.group;
			const user = body.user;
			const invited_by = body.invited_by;

			console.log(`Inviting...`, { user: user, group: group });

			const { data: profile } = await supabase.from('profiles').select('*').eq('user_id', user.user_id).single();
			if (profile.email_invites && !DEV_MODE) {
				const html = template(internal, { full_name: `${user.first_name} ${user.last_name}`, invited_by: invited_by, group_name: group.name });

				const token = await getToken();
				const res = await sendEmail(token, {
					from: 'noreply@giftamizer.com',
					fromName: 'Giftamizer',
					to: user.email,
					subject: 'Giftamizer Invite',
					body: html,
				});
				console.log('Send internal invite: ', res.status, res.statusText);
			}

			context.response.body = 'ok';
		} catch (error) {
			console.log(error);
			context.response.status = 500;
			context.response.body = error.message;
		}
	})
	.post('/invite/external', async (context) => {
		try {
			// Note: request body will be streamed to the function as chunks, set limit to 0 to fully read it.
			const result = context.request.body({ type: 'json', limit: 0 });
			const body = await result.value;
			const group = body.group;
			const user = body.user;
			const invited_by = body.invited_by;
			console.log(`Inviting...`, { user: user, group: group });

			const html = template(external, { invited_by: invited_by, group_name: group.name });

			if (!DEV_MODE) {
				const token = await getToken();
				const res = await sendEmail(token, {
					from: 'noreply@giftamizer.com',
					fromName: 'Giftamizer',
					to: user.email,
					subject: 'Welcome to Giftamizer!',
					body: html,
				});
				console.log('Send external invite: ', res.status, res.statusText);
			}

			context.response.body = 'ok';
		} catch (error) {
			console.log(error);
			context.response.status = 500;
			context.response.body = error.message;
		}
	})
	.post('/invite/secret-santa', async (context) => {
		try {
			// Note: request body will be streamed to the function as chunks, set limit to 0 to fully read it.
			const result = context.request.body({ type: 'json', limit: 0 });
			const body = await result.value;
			const group = body.group;
			const user = body.user;
			const invited_by = body.invited_by;

			console.log(`Inviting...`, { user: user, group: group });

			// send in app notification
			const { error: notificationError } = await supabase.from('notifications').insert([
				{
					user_id: user.user_id,
					title: `${group.name} Secret Santa`,
					body: 'You have been added to a Secret Santa!',
					icon: 'gift',
					action: `openGroup_${group.id}`,
				},
			]);
			if (notificationError) console.log('Secret santa notification error: ', notificationError);

			// send email
			const { data: profile } = await supabase.from('profiles').select('*').eq('user_id', user.user_id).single();
			if (profile.email_invites && !DEV_MODE) {
				const html = template(secretSanta, { full_name: `${user.profile.first_name} ${user.profile.last_name}`, invited_by: invited_by, group_name: group.name, group_id: group.id });

				const token = await getToken();
				const res = await sendEmail(token, {
					from: 'noreply@giftamizer.com',
					fromName: 'Giftamizer',
					to: user.profile.email,
					subject: 'Secret Santa',
					body: html,
				});
				console.log('Send secret santa invite: ', res.status, res.statusText);
			}

			context.response.body = 'ok';
		} catch (error) {
			console.log(error);
			context.response.status = 500;
			context.response.body = error.message;
		}
	});

const app = new Application();
app.use(router.routes());
app.use(router.allowedMethods());

await app.listen({ port: 8000 });
