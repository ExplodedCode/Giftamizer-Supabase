const template = (template: string, data: any) => {
	for (const property in data) {
		console.log(`${property}: ${data[property]}`);

		template = template.replaceAll(`{${property}}`, data[property]);
	}

	return template;
};

export default template;
