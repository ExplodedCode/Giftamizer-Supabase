// Writes the emails that are kept as files. Run it after changing one, or the shared layout.
//
//   node scripts/build-emails.mjs
//
// - volumes/auth/templates: sent by the auth service, which loads them through Kong
//   (volumes/api/email-templates.conf). Their text is below.
// - volumes/functions/invite/templates: copies of the invite emails, to look at. The
//   function sends what is in volumes/functions/invite/emails.js.
import fs from 'node:fs';
import path from 'node:path';

import { external, internal, secretSanta } from '../volumes/functions/invite/emails.js';
import { accent, bold, button, layout, note, plainLink, text } from '../volumes/functions/invite/layout.js';

const VOLUMES = path.resolve(import.meta.dirname, '../volumes');

// Filled in by the auth service (Go html/template). Keep to addresses and links: anything else
// an account holder can set, such as their name, would let them send their own text to others.
const LINK = '{{ .ConfirmationURL }}';
const EMAIL = '{{ .Email }}';
const NEW_EMAIL = '{{ .NewEmail }}';

const auth = {
	confirmation: layout({
		title: 'Confirm your email',
		preview: 'Confirm your email address to finish creating your Giftamizer account.',
		header: 'email-header.jpg',
		badge: 'Welcome',
		heading: `Welcome to ${accent('Giftamizer')}`,
		body: [
			text(`Thanks for signing up! Confirm ${bold(EMAIL)} to finish creating your account.`),
			button('Confirm Email', LINK),
			plainLink(LINK),
			note(`If you didn't create a Giftamizer account, you can ignore this email.`),
		].join('\n'),
	}),
	recovery: layout({
		title: 'Reset your password',
		preview: 'Choose a new password for your Giftamizer account.',
		icon: 'icon-lock.png',
		heading: 'Reset your password',
		body: [
			text(`We got a request to reset the password for ${bold(EMAIL)}. Follow the link below to choose a new one.`),
			button('Reset Password', LINK),
			plainLink(LINK),
			note(`If you didn't ask for this, you can ignore this email. Your password stays the same.`),
		].join('\n'),
	}),
	// Goes to the old and the new address, and both have to confirm.
	email_change: layout({
		title: 'Confirm your new email',
		preview: 'Confirm the new email address for your Giftamizer account.',
		icon: 'icon-mail.png',
		heading: 'Confirm your new email',
		body: [
			text(`Follow the link below to change the email address of your Giftamizer account from ${bold(EMAIL)} to ${bold(NEW_EMAIL)}.`),
			text('We sent this email to both addresses. Your email changes once both are confirmed.'),
			button('Change Email', LINK),
			plainLink(LINK),
			note(`If you didn't ask for this, don't follow the link and your email address stays the same.`),
		].join('\n'),
	}),
};

const invites = {
	'internal-invite': internal,
	'external-invite': external,
	invite: external,
	'secret-santa-invite': secretSanta,
};

for (const [dir, emails] of [
	['auth/templates', auth],
	['functions/invite/templates', invites],
]) {
	fs.mkdirSync(path.join(VOLUMES, dir), { recursive: true });
	for (const [name, html] of Object.entries(emails)) {
		fs.writeFileSync(path.join(VOLUMES, dir, `${name}.html`), html);
		console.log(`${dir}/${name}.html`, `${(html.length / 1024).toFixed(1)} KB`);
	}
}
