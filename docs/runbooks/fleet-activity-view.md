# Mission Control — Co-latro fleet activity view: deploy runbook (PET-187)

Puts the static page at [`tools/mission-control/co-latro-fleet/`](../../tools/mission-control/co-latro-fleet/)
**live behind Cloudflare Access** at **`https://fleet.pdlab.dev`**, gated to a single user
(Pedro) via One-Time PIN.

Architecture: `cloudflared tunnel → http://192.168.50.242:8090` (nginx on the agent-loop
LXC) which serves the static page + a same-origin **mirror** of the MinIO `agent-evals`
bucket. **Cloudflare Access** (edge) is the real boundary; the page's `/whoami` check is
defense-in-depth only.

## Pieces

| Piece | Where |
|---|---|
| Single-email Access support | `modules/cloudflare-ingress/{variables,main}.tf` (`access_emails`) |
| The route + Access app | `environments/homelab/cloudflare-routes.tf` (`fleet.pdlab.dev`, `access=true`) |
| Host config (nginx + mirror) | `ansible/playbooks/configure-fleet.yml` + `files/fleet-nginx.conf` + `templates/fleet-evals-mirror.{service,timer}.j2` |

## One-time prerequisites (Pedro, Cloudflare dashboard) — **required before merge**

The first-ever Cloudflare Access app from this repo needs the Zero Trust org to exist, or
the apply-on-merge creates the CNAME but **fails** on the Access app (leaving `fleet.pdlab.dev`
routed but **ungated**). Confirm in the Cloudflare One / Zero Trust dashboard:

1. **Zero Trust org / team domain** exists (`<team>.cloudflareaccess.com`). If Zero Trust has
   never been opened, complete the one-time "choose a team name" onboarding (free ≤50 seats).
2. **One-Time PIN** login method enabled (Settings → Authentication → Login methods). This
   backs the single-email policy (no Authentik IdP yet — `allowed_idps` is empty; PET-38).
3. The Cloudflare API token in Vault `kv/iac/cloudflare` has **Access: Apps and Policies →
   Edit** (it already manages tunnel/DNS; confirm the Access scope is present).

## Deploy

**Order matters:** stand up the origin (step 1, Ansible) **before** merging the Terraform PR
(step 2). If the public hostname resolves before nginx is up, the gated URL returns 502 until
the play runs. (The module's `depends_on` also keeps the public CNAME from being created before
its Access gate, so a failed prereq leaves no ungated URL.)

### 1. Ansible — stand up the origin (run first; operator-run, no CI path covers this)

From the iac clone. This is safe before the route exists — `242:8090` is LAN-only until the
tunnel route is added in step 2:

```bash
export VAULT_ADDR=https://192.168.50.223:8200
export VAULT_CACERT="$(git rev-parse --show-toplevel)/environments/homelab/vault-ca.crt"
export VAULT_TOKEN=$(security find-generic-password -s vault-root-token -w)   # Keychain root token

umask 077
vault kv get -format=json kv/services/agent-loop \
  | jq '{minio_evals_ak:.data.data.mc_access_key, minio_evals_sk:.data.data.mc_secret_key}' \
  > /tmp/fleet-evars.json

cd ansible
ansible-playbook playbooks/configure-fleet.yml -e @/tmp/fleet-evars.json
shred -u /tmp/fleet-evars.json
```

(The `agent-loop` group → `root@192.168.50.242` over `~/.ssh/id_ed25519_ansible`. The play
needs no extra collections — just nginx + mc + systemd builtins.) Confirm the origin is up:
`ssh root@192.168.50.242 'ss -ltnp | grep :8090 && curl -s localhost:8090/whoami'`.

### 2. Terraform — the route + gate (apply-on-merge)

Merge the PR **only after the §prerequisites are confirmed**. CI (`terraform` workflow,
self-hosted apply job) runs `terraform apply` and creates, for `fleet.pdlab.dev`: a proxied
CNAME, the tunnel ingress rule (`→ 192.168.50.242:8090`), a
`cloudflare_zero_trust_access_application`, and an `access_policy` with
`include = [{ email = { email = "pedelgadillo@gmail.com" } }]`.

> Verify the apply log, not just the green PR check (`validate`-on-PR never touches Cloudflare).
> Confirm the plan shows the **4 existing routes retained** + `fleet` added, and that **both**
> Access resources (`application` *and* `policy`) were created — a CNAME without the Access app
> is the dangerous half-apply.

## Verify

```bash
# Edge gate enforced — unauthenticated must 302 to the Access login:
curl -sI https://fleet.pdlab.dev/ | grep -i location   # -> *.cloudflareaccess.com/cdn-cgi/access/login

# Origin reachable on the host (bypassing CF):
ssh root@192.168.50.242 'curl -s http://127.0.0.1:8090/whoami'   # -> {"username":"pedro"}
ssh root@192.168.50.242 'ls /var/www/fleet/agent-evals/'         # -> *.jsonl after first mirror
```

Then open `https://fleet.pdlab.dev` in a browser → Access redirects → "Send me a code" →
enter the One-Time PIN emailed to `pedelgadillo@gmail.com` → the fleet page loads. **Only
Pedro can complete this** (the code goes to his inbox).

## Hazards

- **Don't merge before the §prereqs.** A missing Zero Trust org / token scope makes the
  Access app fail *after* merge, leaving the route ungated until re-applied. If the apply
  half-fails, fix the prereq and re-run apply (resources are idempotent); don't publicize
  the URL until the 302 is confirmed.
- The `agent-evals` JSONL is LAN-reachable on `242:8090` (like the co-latro origin on 230) —
  the public boundary is Cloudflare Access. JWT-validation at the origin (njs/lua) is a
  possible hardening follow-up; not required for the single-user gate.
- To gate by Authentik later (PET-38): create the OIDC IdP, then set `allowed_idps` on the
  route — additive, no other change.
