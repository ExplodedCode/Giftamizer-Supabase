// Invite emails. {property} placeholders are filled in (and HTML-escaped) by template.ts.
// After a change, run `node scripts/build-emails.mjs` to update templates/.
import { accent, bold, button, layout, SITE, text } from './layout.js';

// To someone who already has an account.
export const internal = layout({
	title: 'Giftamizer Invite',
	preview: '{invited_by} has invited you to join the {group_name} group.',
	header: 'email-header.jpg',
	badge: 'Group invite',
	heading: `You've been invited to join ${accent('Giftamizer')}`,
	body: [
		text('Hello {full_name}!'), //
		text(`${bold('{invited_by}')} has invited you to join the ${bold('{group_name}')} group!`),
		button('Accept Invite', `${SITE}/#group-invitations`),
	].join('\n'),
});

// To an email address without an account.
export const external = layout({
	title: 'Welcome to Giftamizer!',
	preview: '{invited_by} has invited you to join the {group_name} group on Giftamizer.',
	header: 'email-header.jpg',
	badge: 'Welcome',
	heading: `You've been invited to join ${accent('Giftamizer')}`,
	body: [
		text(
			`Hello! We're excited to invite you to join Giftamizer, an online gift registry and shopping platform. Giftamizer makes it easy for friends and family to find the perfect gifts for your special occasions.`
		),
		text(
			`${bold('{invited_by}')} has invited you to join the ${bold('{group_name}')} group on Giftamizer. Our records show that you don't have an account yet. Create your account with this email address and you'll be added to the group!`
		),
		button('Get Started', SITE),
	].join('\n'),
});

export const secretSanta = layout({
	title: 'Secret Santa',
	preview: 'Sign in now to see whose name you drew!',
	header: 'email-header-secret-santa.jpg',
	badge: 'Secret Santa',
	heading: `You've been invited to join ${accent('Secret Santa')}`,
	body: [
		text('Hello {full_name}!'),
		text(`${bold('{invited_by}')} has created a Secret Santa name drawing for the ${bold('{group_name}')} group on Giftamizer. Sign in now to see whose name you drew!`),
		button('Sign In', `${SITE}/groups/{group_id}`),
	].join('\n'),
});
