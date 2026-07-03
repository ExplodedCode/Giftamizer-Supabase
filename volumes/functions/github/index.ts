import { Application, Router } from 'https://deno.land/x/oak@v12.6.1/mod.ts';

// Powers the Support page (Support.tsx) issue tracker: lists and creates
// issues against a GitHub repo on behalf of the app, using a server-side
// token so users don't need their own GitHub account.
const GITHUB_TOKEN = Deno.env.get('GITHUB_TOKEN');
const GITHUB_OWNER = Deno.env.get('GITHUB_OWNER');
const GITHUB_REPO = Deno.env.get('GITHUB_REPO');

const GITHUB_API_URL = 'https://api.github.com';

function isConfigured() {
	return Boolean(GITHUB_TOKEN && GITHUB_OWNER && GITHUB_REPO);
}

function githubHeaders() {
	return {
		Authorization: `Bearer ${GITHUB_TOKEN}`,
		Accept: 'application/vnd.github+json',
		'X-GitHub-Api-Version': '2022-11-28',
		'User-Agent': 'giftamizer-supabase-functions',
	};
}

const router = new Router();
router
	// Cheap check the frontend uses to show/hide the Support nav item -
	// does not call the GitHub API.
	.post('/github/status', (context) => {
		context.response.body = { configured: isConfigured() };
	})
	.post('/github/issues', async (context) => {
		if (!isConfigured()) {
			context.response.status = 501;
			context.response.body = { msg: 'GitHub integration is not configured' };
			return;
		}

		try {
			const res = await fetch(`${GITHUB_API_URL}/repos/${GITHUB_OWNER}/${GITHUB_REPO}/issues?state=open`, {
				headers: githubHeaders(),
			});
			const data = await res.json();

			if (!res.ok) {
				console.error('Failed to list issues:', data);
				context.response.status = res.status;
				context.response.body = data;
				return;
			}

			context.response.body = data;
		} catch (error) {
			console.error(error);
			context.response.status = 500;
			context.response.body = { msg: error.message };
		}
	})
	.post('/github/issues/create', async (context) => {
		if (!isConfigured()) {
			context.response.status = 501;
			context.response.body = { msg: 'GitHub integration is not configured' };
			return;
		}

		try {
			// Note: request body will be streamed to the function as chunks, set limit to 0 to fully read it.
			const result = context.request.body({ type: 'json', limit: 0 });
			const body = await result.value;
			const { title, body: issueBody, labels } = body;

			if (!title || !issueBody) {
				context.response.status = 400;
				context.response.body = { msg: 'title and body are required' };
				return;
			}

			const res = await fetch(`${GITHUB_API_URL}/repos/${GITHUB_OWNER}/${GITHUB_REPO}/issues`, {
				method: 'POST',
				headers: { ...githubHeaders(), 'Content-Type': 'application/json' },
				body: JSON.stringify({ title, body: issueBody, labels }),
			});
			const data = await res.json();

			if (!res.ok) {
				console.error('Failed to create issue:', data);
				context.response.status = res.status;
				context.response.body = data;
				return;
			}

			context.response.body = data;
		} catch (error) {
			console.error(error);
			context.response.status = 500;
			context.response.body = { msg: error.message };
		}
	});

const app = new Application();
app.use(router.routes());
app.use(router.allowedMethods());

await app.listen({ port: 8000 });
