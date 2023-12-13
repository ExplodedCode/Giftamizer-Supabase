const TENANT_ID = Deno.env.get('TENANT_ID');
const CLIENT_ID = Deno.env.get('CLIENT_ID');
const CLIENT_SECRET = Deno.env.get('CLIENT_SECRET');

export const getToken = async () => {
	console.log('Get Token... ', TENANT_ID, CLIENT_ID, CLIENT_SECRET);

	const body = new FormData();
	body.set('grant_type', 'client_credentials');
	body.set('client_id', CLIENT_ID || '');
	body.set('client_secret', CLIENT_SECRET || '');
	body.set('resource', 'https://graph.microsoft.com');

	const url = `https://login.microsoftonline.com/${TENANT_ID || ''}/oauth2/token`;
	const res = await fetch(url, { method: 'POST', body });
	console.log('Get token: ', res.status, res.statusText);
	const data = await res.json();
	return data.access_token;
};

export const sendEmail = (token: string, email: Email) => {
	const url = `https://graph.microsoft.com/v1.0/users/${email.from}/sendMail`;
	return fetch(url, {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',

			Authorization: `Bearer ${token}`,
		},
		body: JSON.stringify({
			message: {
				from: {
					emailAddress: {
						name: 'Giftamizer',
						address: 'noreply@giftamizer.com',
					},
				},
				subject: email.subject,
				body: {
					contentType: 'HTML',
					content: email.body,
				},
				toRecipients: [
					{
						emailAddress: {
							address: email.to,
						},
					},
				],
			},
			saveToSentItems: 'true',
		}),
	});
};
export interface Email {
	from: string;
	fromName: string;
	to: string;
	subject: string;
	body: string;
}
