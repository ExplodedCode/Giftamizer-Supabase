import 'https://deno.land/x/xhr@0.1.0/mod.ts';

import base64 from 'https://deno.land/x/b64@1.1.27/src/base64.js';
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import axiod from 'https://deno.land/x/axiod/mod.ts';

serve(async (req) => {
	const { user_id, url } = await req.json();

	console.log(`Download avatar for ${user_id}: ${url}`);

	if (url && user_id) {
		try {
			const { data } = await axiod({
				url,
				method: 'GET',
				responseType: 'arraybuffer',
			});

			return new Response(`data:image/jpeg;base64,${base64.fromArrayBuffer(data)}`, { headers: { 'Content-Type': 'text/html', Connection: 'keep-alive' } });
		} catch (error) {
			console.error(error);
			return new Response(error.message, { status: 500 });
		}
	} else {
		return new Response('Invalid Request', { status: 500 });
	}
});
