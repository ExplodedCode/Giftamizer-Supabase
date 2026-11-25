const HTML_ESCAPES: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

const escapeHtml = (value: string) => value.replace(/[&<>"']/g, (char) => HTML_ESCAPES[char]);

// Replaces {property} placeholders with HTML-escaped values.
const template = (template: string, data: Record<string, string>) =>
	template.replace(/\{(\w+)\}/g, (placeholder, property) => (Object.hasOwn(data, property) ? escapeHtml(data[property]) : placeholder));

export default template;
