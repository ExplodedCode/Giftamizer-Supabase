import 'https://deno.land/x/xhr@0.1.0/mod.ts';

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import axios from 'https://esm.sh/axios@1.4.0';

serve(async (req) => {
	const { url } = await req.json();

	console.log(`Get metadata: ${url}`);

	if (url) {
		try {
			const { data } = await axios.post('http://urlmetadata', {
				url: url,
			});

			return new Response(JSON.stringify(data), { headers: { 'Content-Type': 'application/json' } });
		} catch (error) {
			console.error(error);
			return new Response(error.message, { status: 500 });
		}
	} else {
		return new Response('Invalid Request', { status: 500 });
	}
});
