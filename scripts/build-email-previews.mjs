// Rebuilds email-previews: every email in desktop and mobile, light and dark, filled with
// made-up data. Run `node scripts/build-emails.mjs` first if a template changed.
//
//   node scripts/build-email-previews.mjs
//
// Needs Node 22.18+, Edge or Chrome, and the frontend checkout, whose email images are built
// into the previews. Settings, if something isn't found:
//   FRONTEND   the frontend checkout (default: ../Giftamizer, next to this repo)
//   BROWSER    path of Edge or Chrome
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { external, internal, secretSanta } from '../volumes/functions/invite/emails.js';
import fillInvite from '../volumes/functions/invite/template.ts';

const ROOT = path.resolve(import.meta.dirname, '..');
const OUT = path.join(ROOT, 'email-previews');
const IMAGES = path.join(process.env.FRONTEND ?? path.resolve(ROOT, '../Giftamizer'), 'public/images/email');
if (!fs.existsSync(IMAGES)) throw new Error(`No email images in ${IMAGES}. Set FRONTEND to the frontend checkout.`);

const BROWSER = [
	process.env.BROWSER,
	'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
	'C:/Program Files/Google/Chrome/Application/chrome.exe',
	'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
	'/usr/bin/google-chrome',
	'/usr/bin/chromium',
].find((p) => p && fs.existsSync(p));
if (!BROWSER) throw new Error('No browser found. Set BROWSER to the path of Edge or Chrome.');

// ------------------------------------------------------------------ the emails, filled in
const read = (file) => fs.readFileSync(path.join(ROOT, 'volumes', file), 'utf8');

const invite = (html) =>
	fillInvite(html, { full_name: 'Alice Whitaker', invited_by: 'Carla Chen', group_name: "Mom & Dad's Family", group_id: '5b1f7c1e-8a52-4c0e-9d0b-2f6f3f1f9a10' });

// as the auth service does it: Go's html/template drops comments and escapes values
const ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&#34;', "'": '&#39;' };
const auth = (name, type, redirect) => {
	const values = {
		ConfirmationURL: `https://api.giftamizer.com/auth/v1/verify?token=0123456789abcdef0123456789abcdef0123456789abcdef01234567&type=${type}&redirect_to=${redirect}`,
		Email: 'alice@example.com',
		NewEmail: 'alice.whitaker@example.com',
	};
	return read(`auth/templates/${name}.html`)
		.replace(/<!--[\s\S]*?-->/g, '')
		.replace(/\{\{ \.(\w+) \}\}/g, (_, key) => values[key].replace(/[&<>"']/g, (c) => ESCAPES[c]));
};

const emails = [
	['1-confirmation', 'Sign-up confirmation', 'Auth service', auth('confirmation', 'signup', 'https://giftamizer.com')],
	['2-recovery', 'Password reset', 'Auth service', auth('recovery', 'recovery', 'https://giftamizer.com/recover')],
	['3-email-change', 'Email change', 'Auth service, to the old and new address', auth('email_change', 'email_change', 'https://giftamizer.com')],
	['4-internal-invite', 'Group invite', 'Invite function, to people with an account', invite(internal)],
	['5-external-invite', 'Welcome invite', 'Invite function, to people without an account (invite.html is identical)', invite(external)],
	['6-secret-santa', 'Secret Santa', 'Invite function', invite(secretSanta)],
	['7-giftamizer-2.0', 'Giftamizer 2.0', 'One-off announcement', read('functions/invite/templates/Giftamizer 2.0 Email.html')],
].map(([name, title, sender, html]) => {
	const left = html.match(/\{\{.*?\}\}|\{\w+\}/);
	if (left) throw new Error(`${name}: ${left[0]} isn't filled in`);

	// build the images in, so a preview doesn't depend on what is deployed
	const embedded = html.replace(/https:\/\/giftamizer\.com\/images\/email\/([\w.-]+)/g, (_, file) => {
		const type = file.endsWith('jpg') ? 'jpeg' : 'png';
		return `data:image/${type};base64,${fs.readFileSync(path.join(IMAGES, file)).toString('base64')}`;
	});
	return { name, title, sender, html: embedded };
});

const views = [
	{ dir: 'desktop-light', label: 'Desktop', width: 720, scheme: 'light', shown: 600 },
	{ dir: 'desktop-dark', label: 'Desktop, dark', width: 720, scheme: 'dark', shown: 600 },
	{ dir: 'mobile-light', label: 'Mobile', width: 390, scheme: 'light', shown: 325 },
	{ dir: 'mobile-dark', label: 'Mobile, dark', width: 390, scheme: 'dark', shown: 325 },
];

// ------------------------------------------------------------------ browser
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'giftamizer-emails-'));
const browser = spawn(BROWSER, ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run', '--hide-scrollbars', '--force-color-profile=srgb', '--disable-gpu', '--num-raster-threads=1', 'about:blank'], { stdio: 'ignore' }); // no GPU: the same picture every run
process.on('exit', () => browser.kill()); // also after an error

const portFile = path.join(profile, 'DevToolsActivePort');
for (let i = 0; i < 100 && !fs.existsSync(portFile); i++) await sleep(150);
await sleep(200);
const [port, wsPath] = fs.readFileSync(portFile, 'utf8').trim().split('\n');
const ws = new WebSocket(`ws://127.0.0.1:${port}${wsPath.trim()}`);
await new Promise((res, rej) => ((ws.onopen = res), (ws.onerror = rej)));

let lastId = 0;
const pending = new Map();
ws.onmessage = ({ data }) => {
	const message = JSON.parse(data);
	const request = pending.get(message.id);
	if (!request) return;
	pending.delete(message.id);
	message.error ? request.rej(new Error(message.error.message)) : request.res(message.result);
};
const send = (method, params = {}, sessionId) =>
	new Promise((res, rej) => {
		pending.set(++lastId, { res, rej });
		ws.send(JSON.stringify({ id: lastId, method, params, sessionId }));
	});

const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
const page = (method, params) => send(method, params, sessionId);
await page('Page.enable');

// Full-page PNG of `html`, `dpr` times larger than `width`. Warns if it is wider than that.
async function shot(html, { width, scheme = 'light', dpr = 2, name }) {
	await page('Emulation.setDeviceMetricsOverride', { width, height: 400, deviceScaleFactor: dpr, mobile: width < 500 });
	await page('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }] });
	const { frameTree } = await page('Page.getFrameTree');
	await page('Page.setDocumentContent', { frameId: frameTree.frame.id, html });
	await sleep(600);
	await page('Runtime.evaluate', { expression: 'document.fonts.ready.then(() => 1)', awaitPromise: true });
	const { result } = await page('Runtime.evaluate', {
		expression: '[document.body.lastElementChild.getBoundingClientRect().height, document.documentElement.scrollWidth]',
		returnByValue: true,
	});
	const [height, scrollWidth] = result.value;
	if (scrollWidth > width) console.warn(`${name}: ${scrollWidth}px wide on a ${width}px screen`);
	const { data } = await page('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: 0, y: 0, width, height: Math.ceil(height), scale: 1 } });
	return Buffer.from(data, 'base64');
}

// ------------------------------------------------------------------ output
// Windows refuses to overwrite a file another program is reading, such as an image viewer
async function save(file, data) {
	for (let attempt = 1; ; attempt++) {
		try {
			return fs.writeFileSync(path.join(OUT, file), data);
		} catch (error) {
			if (attempt === 10) throw error;
			await sleep(300);
		}
	}
}

for (const dir of ['html', ...views.map((v) => v.dir)]) fs.mkdirSync(path.join(OUT, dir), { recursive: true });

for (const { name, html } of emails) {
	await save(`html/${name}.html`, html);
	for (const { dir, width, scheme } of views) {
		await save(`${dir}/${name}.png`, await shot(html, { width, scheme, name: `${name}, ${dir}` }));
	}
	console.log(name);
}

// everything in one picture
const pictures = emails.map(({ name }) => `<img src="data:image/png;base64,${fs.readFileSync(path.join(OUT, 'desktop-light', `${name}.png`)).toString('base64')}" style="display:block;width:420px" />`);
await save(
	'overview.png',
	await shot(`<!doctype html><body style="margin:0;background:#e4e4e7"><div style="display:grid;grid-template-columns:repeat(4,420px);gap:20px;padding:20px;align-items:start">${pictures.join('')}</div></body>`, {
		width: 1780,
		dpr: 1,
		name: 'overview',
	})
);

await save(
	'index.html',
	`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Giftamizer email previews</title>
<style>
	body { margin: 0; background: #e4e4e7; color: #09090b; font: 15px/1.5 Inter, 'Segoe UI', sans-serif; }
	nav { position: sticky; top: 0; z-index: 1; display: flex; flex-wrap: wrap; gap: 8px 18px; padding: 14px 28px; background: #fff; border-bottom: 1px solid #d4d4d8; }
	nav b { margin-right: 8px; }
	a { color: #047857; }
	section { padding: 28px 28px 12px; scroll-margin-top: 50px; }
	h2 { margin: 0; font-size: 20px; letter-spacing: -.02em; }
	p { margin: 2px 0 16px; color: #52525b; }
	.row { display: flex; gap: 20px; align-items: flex-start; overflow-x: auto; padding-bottom: 12px; }
	figure { margin: 0; flex: none; }
	figcaption { margin-bottom: 6px; font-size: 13px; color: #52525b; }
	img { display: block; border-radius: 12px; box-shadow: 0 1px 3px rgba(0, 0, 0, .2); }
</style>
</head>
<body>
<nav><b>Email previews</b>${emails.map(({ name, title }) => `<a href="#${name}">${title}</a>`).join('')}</nav>
${emails
	.map(
		({ name, title, sender }) => `<section id="${name}">
	<h2>${title}</h2>
	<p>${sender}. <a href="html/${name}.html" target="_blank">Open the live email</a></p>
	<div class="row">
${views.map(({ dir, label, shown }) => `		<figure><figcaption>${label}</figcaption><a href="${dir}/${name}.png" target="_blank"><img src="${dir}/${name}.png" width="${shown}" alt="${title}, ${label}" loading="lazy" /></a></figure>`).join('\n')}
	</div>
</section>`
	)
	.join('\n')}
</body>
</html>
`
);

try {
	await Promise.race([send('Browser.close'), sleep(2000)]);
} catch {}
browser.kill();
await sleep(500);
try {
	fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
} catch {}
process.exit(0);
