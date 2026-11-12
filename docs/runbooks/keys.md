# Agent keys: Cloudflare Access service tokens

Each agent that calls a lab service over HTTPS, such as Pedro's Muse (`muse`) or Sonia's
(`batsy`), holds one Cloudflare Access service token. The agent sends it in one header,
`Authorization`, the only name Cloudflare accepts for a one-header token. Cloudflare refuses any other request at the edge. The design is
[Lab access and keys](https://claude.ai/artifact/6A23RZ9uT4X74qWX5sHBuy).

| Piece | Where |
|---|---|
| Who holds a token, and who owns that agent | `secrets/callers.yml` |
| The token's one-header value | Vault, `kv/callers/edge/<agent>`, field `header` |
| Owner, token id, client id and expiry | the same path's custom metadata |
| Which services an agent may call | each route's `agents` list in `environments/homelab/cloudflare-routes.tf` |
| Create, rotate, revoke | `.github/workflows/keys.yml`, running `scripts/keys.py` |
| The Cloudflare token `keys.yml` uses | `kv/services/keys-cloudflare`, placed by `scripts/seed-keys-cloudflare.sh` |
| The Vault roles | `environments/homelab/vault-config/keys.tf` |

## One-time setup

Pedro does these three steps once.

1. In the Cloudflare dashboard, create a custom API token with one permission: **Account >
   Access: Service Tokens > Edit**. Copy it, then run `scripts/seed-keys-cloudflare.sh` on the Mac.
2. Apply `vault-config` with `scripts/apply-vault-config.sh`. The gated `vault-config-apply`
   path cannot create the `keys-*` roles, by design.
3. Dispatch `keys.yml` with `action=list`. A green run with `read 2 agents` proves `keys-list`.
4. Add **Account > Access: Service Tokens > Read** to the Terraform Cloudflare token
   (`homelab-tunnel-management`, at `kv/iac/cloudflare`). A route with `agents` reads the
   `agent-*` tokens through a data source. Without that permission, Cloudflare answers with an
   empty list, and the plan fails on "A route lists an agent with no service token".

## Give an agent a token

1. Add the agent to `secrets/callers.yml` with its owner, and add its
   `kv/callers/edge/<agent>` entry to `secrets/register.yml`. Merge the PR.
2. Dispatch `keys.yml` with `action=sync`. The `plan` job prints `plan: create <agent>` and a
   digest. Pedro reads it and approves the `lab-write` step on the run's web page.
3. The owner copies the `header` field from Vault and enters it in the agent's credential store.
   On the Mac, `scripts/keys-copy.sh <agent>` puts it on the clipboard without printing it.
   For a Muse agent, that is `credentials.request_api_access` with placement
   `custom_header:Authorization` and the host in `api_hosts`. Never send it by email or chat.

## Let an agent call a service

Add the agent's name to the route's `agents` list, with `access = true`. The module adds a
`non_identity` policy for the agent's token, reads the header with
`read_service_tokens_from_header`, and answers a refused agent with a 401. The service must also
map the JWT's `common_name`, the token's client id, to the caller name. To find the client id, run
`keys.yml action=list` or read the path's metadata.

A route that lists an agent with no token fails its plan with a precondition. Run `sync` first.

## Rotate

Dispatch `keys.yml` with `action=rotate` and `name=<agent>`, then approve. The old secret keeps
working for 24 hours. The token keeps its expiry. The owner replaces the stored value in the agent
within that window. For a Muse agent, that is `request_api_access` with `reconnect: true`.

## Renew

To extend a token before it expires, dispatch `action=renew` with `name=<agent>`, then approve.
It sets the token to 90 days from now. The token id, client id and secret stay the same, so no
route, door or agent changes. `renew` reads the expiry back and refuses unless Cloudflare reports
at least 89 days. The nightly register check reads the same date from the path's metadata and
warns 21 days ahead. `keys.py` never calls Cloudflare's refresh, which extends a token by one year.

## Reissue

To replace a token Cloudflare lost, or when `renew` refuses, dispatch `action=reissue`. It
deletes the token and creates another, so the old secret stops at once. The plan says what else
changes: the token id and the client id.

1. Tell the owner first. The agent is refused until they store the new value.
2. Run a Terraform apply of `environments/homelab` so each route that lists the agent points at
   the new token id. Until then those routes refuse it.
3. Give each door that maps the agent the new client id, from `action=list`.

## Drift

`sync` lists Cloudflare's `agent-*` tokens before it changes anything. It refuses, and changes
nothing, in two cases:

- Vault describes a token that Cloudflare no longer has, for example after a dashboard delete.
  Run `action=reissue` for that agent.
- Cloudflare holds an `agent-*` token that `callers.yml` and Vault do not know. Delete it under
  **Access > Service credentials**, or add the agent to `callers.yml`.

## Revoke

Delete the agent from `secrets/callers.yml` and from every route's `agents` list, merge, then run
`sync`. It deletes the Cloudflare token and destroys the Vault entry. Every route refuses the token
at once. A token that Cloudflare already deleted counts as revoked, so a retry finishes. To cut a
token off before a PR can merge, delete it in the Cloudflare dashboard under **Access > Service
credentials**. The next `sync` then refuses for that agent until you run `reissue`.

## What the log shows

`keys.py` prints names, versions, owners and dates. Each command's last line says what it read,
for example `keys sync: read 2 agents, 0 Vault entries, 0 Cloudflare agent tokens; created 2`.
It registers each new secret with `::add-mask::` and never prints a Cloudflare response body.
