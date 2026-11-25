import nodemailer from 'npm:nodemailer@7.0.10';

// Same SMTP_* settings the `auth` service uses (see .env): Brevo in production,
// Inbucket in local dev.
const SMTP_HOST = Deno.env.get('SMTP_HOST');
const SMTP_PORT = Number(Deno.env.get('SMTP_PORT') || 587);
const SMTP_USER = Deno.env.get('SMTP_USER');
const SMTP_PASS = Deno.env.get('SMTP_PASS');
const SMTP_ADMIN_EMAIL = Deno.env.get('SMTP_ADMIN_EMAIL');
const SMTP_SENDER_NAME = Deno.env.get('SMTP_SENDER_NAME') || 'Giftamizer';

// Port 465 is TLS from the start; other ports upgrade with STARTTLS.
const secure = SMTP_PORT === 465;
const useAuth = Boolean(SMTP_USER && SMTP_PASS);

const transporter = nodemailer.createTransport({
	host: SMTP_HOST,
	port: SMTP_PORT,
	secure,
	// Never send credentials over a connection that wasn't upgraded to TLS.
	requireTLS: useAuth && !secure,
	auth: useAuth ? { user: SMTP_USER, pass: SMTP_PASS } : undefined,
	// Fail well before the edge function worker timeout (60s, see main/index.ts).
	connectionTimeout: 10000,
	greetingTimeout: 10000,
	socketTimeout: 20000,
});

export interface Email {
	to: string;
	subject: string;
	body: string;
}

// Throws if the SMTP server can't be reached or rejects the message.
export const sendEmail = async (email: Email): Promise<string> => {
	if (!SMTP_HOST || !SMTP_ADMIN_EMAIL) throw new Error('SMTP is not configured');

	const info = await transporter.sendMail({
		from: { name: SMTP_SENDER_NAME, address: SMTP_ADMIN_EMAIL },
		// Object form so the value is used as one address, never parsed as a list.
		to: { name: '', address: email.to },
		subject: email.subject,
		html: email.body,
	});
	return info.response;
};
