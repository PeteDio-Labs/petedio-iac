// Placeholder so Terraform can create the function. The deploy workflow replaces it with
// dashboard/api/dist/handler.mjs from pete-bot. A response from this file means no deploy ran.
export const handler = async () => ({
  statusCode: 503,
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ ok: false, error: "placeholder handler: the API has not been deployed" }),
});
