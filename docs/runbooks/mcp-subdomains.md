# Move the MCP connectors to their own hostnames (PET-824)

The apex `pdlab.dev` serves the portfolio from CloudFront after PET-816, so the Plane and lab
MCP connectors leave it. This runbook switches them without a gap for Plane and with a short one
for the lab connector. Pedro runs steps 2 to 4.

| Connector | Old URL | New URL |
|---|---|---|
| Plane | `https://pdlab.dev/mcp/plane` | `https://mcp-plane.pdlab.dev/mcp` |
| Lab | `https://pdlab.dev/mcp/lab` | `https://mcp-lab.pdlab.dev/mcp/lab` |

1. **Merge the PR that adds the routes.** The apply on merge creates two DNS records and two
   Access applications. The old path routes keep answering.
2. **Plane.** Add a connector at the new URL on claude.ai and sign in. Call a tool from a thread.
   Remove the old connector.
3. **Lab.** Read the new audience tag and deploy it, which ends the old path route:
   ```bash
   (cd environments/homelab && terraform output -raw lab_mcp_subdomain_access_aud)
   ```
   Set `lab_agent_access_aud` in `ansible/playbooks/configure-pete-bot.yml` to that value in a
   PR, merge it, and run the configure-pete-bot play. Add the new lab connector, call a tool,
   and remove the old connector.
4. **Check both.** `scripts/lab-mcp-check.sh` probes the edge, the Plane shim, the 237 listener
   and the audience tags, and exits 1 on any failed probe (`PET-827`). Before step 3 the lab
   listener is off, because `lab_agent_access_aud` is empty. An unauthenticated request must
   return 401:
   ```bash
   curl -sI https://mcp-plane.pdlab.dev/mcp | head -1
   curl -sI https://mcp-lab.pdlab.dev/mcp/lab | head -1
   ```
5. **Remove the old routes** in a second PR: delete `pdlab.dev/mcp/plane` and `pdlab.dev/mcp/lab`
   from `environments/homelab/cloudflare-routes.tf`, and the old `lab_mcp_access_aud` output. Do
   this before the apex cutover, which would otherwise leave their Access applications orphaned.

Rollback: the path routes stay until step 5, so step 2 and 3 can be reversed by re-adding the old
connector. After step 3, the lab path route fails until `lab_agent_access_aud` is set back.
