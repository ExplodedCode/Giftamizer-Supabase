import 'https://deno.land/x/xhr@0.1.0/mod.ts';
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.33.1';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const supabase = createClient(SUPABASE_URL || '', SUPABASE_SERVICE_ROLE_KEY || '');

serve(async (req) => {
	try {
		const { user_id } = await req.json();
		const accessToken = await req.headers.get('authorization')?.split('Bearer ')[1];

		if (accessToken) {
			console.log(`Deleting user: ${user_id}`);

			// validate access token JWT and UID match
			const {
				data: { user },
			} = await supabase.auth.getUser(accessToken);
			if (!user || user.id !== user_id) {
				return new Response('Unauthorized!', { status: 401 });
			}

			// delete user
			const { error } = await supabase.auth.admin.deleteUser(user_id);
			if (error) {
				console.error(error);
				return new Response('Invalid Request!', { status: 500 });
			}

			return new Response('ok', { status: 200 });
		} else {
			return new Response('Unauthorized!', { status: 401 });
		}
	} catch (error) {
		console.error(error);
		return new Response('Invalid Request!', { status: 500 });
	}
});
