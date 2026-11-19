# Authentik on AWS

Terraform for the off-prem copy of Authentik (`PET-932`). It runs the same stack as LXC 119 on one EC2 host, so a lab outage no longer takes `auth.pdlab.dev` down. The LDAP outpost stays in the lab and connects out to `auth.pdlab.dev`. Authentik is the first service of the lab's failover switch, which the dashboard thread builds.

## What it creates

| Part | Resource | Notes |
|---|---|---|
| Network | VPC `10.72.0.0/24`, one public subnet, an internet gateway | No NAT gateway. The default security group has no rules. |
| Host | `t4g.small`, Amazon Linux 2023 arm64, 30 GB encrypted gp3 | IMDSv2 with one hop, so a container cannot read the instance credentials. Termination protection is on. |
| Firewall | Security group with no ingress rule | The login page arrives through the `authentik-aws` Cloudflare tunnel, which the host dials out to. |
| Shell | SSM Session Manager | No SSH port and no key. Tailscale SSH is optional, after `--tailscale`. |
| Bucket | `petedio-authentik-<account>` | `config/` (what the host syncs), `migrate/` (the copy from 119, 14 days), `backups/` (nightly, 14 days). Versioned, TLS only, no public access. |
| Role | `petedio-authentik-host` with the `petedio-authentik-boundary` boundary | Reads its own SSM parameters and bucket. Writes only `backups/`. |

The Cloudflare side is in `environments/homelab/cloudflare-authentik-aws.tf`: the tunnel, the `auth-aws.pdlab.dev` test name, and `var.authentik_side`, which points `auth.pdlab.dev` at the lab or at AWS.

## How the host stays declared

User data installs Docker and a timer, once. Every two minutes the timer runs `files/authentik-sync.sh`, which Terraform keeps in `config/`. The script:

1. Syncs `config/` and installs the compose file, the scripts and a nightly backup timer.
2. Reads `.env` and the tunnel token from SSM. It waits, with exit 0, while either is missing.
3. Restores the newest copy under `migrate/` when `settings.env` says `ACCEPT_RESTORE=true`. It checks each file against the digest in `migrate/READY` and refuses a database with no users.
4. Starts the stack and waits for it to report healthy.

It never starts an empty Authentik. A fresh install serves its initial-setup flow to anyone, so the stack stays down until the first copy is restored. Each run writes `/opt/authentik/state/status.json` with what it examined.

To change the Authentik version, change `authentik_version` here and in `ansible/roles/authentik/defaults/main.yml` together while both copies exist, then run the apply. The host pulls the image on its next sync.

## Cost

About $15 to $18 a month after the credits end on 2027-04-20, and $0 before:

- `t4g.small`: about $12.30.
- 30 GB gp3: about $2.40.
- The public IPv4 address: about $3.65. It accepts nothing; it replaces a $32 NAT gateway.
- S3 and SSM: cents.

The tags `project=petedio-authentik` and `expires=2027-04-20` mark every resource.

## Rollout

Pedro runs the two scripts, because they place credentials (`PET-511`). Everything else is a merge or a tapped run.

1. **Merge this PR.** The homelab apply on merge creates the `authentik-aws` tunnel and `auth-aws.pdlab.dev`. `auth.pdlab.dev` stays on the lab, because `authentik_side` is `lab`.
2. **Vault policy.** Dispatch `vault-config-apply.yml` and approve it. It lets `aws-apply.yml` read the `authentik-*` keys.
3. **CI users.** Pedro runs `./scripts/seed-aws-ci.sh --profile <profile>` on the Mac. It adds the `authentik` plan and apply users and the boundary, and leaves the existing keys as they are.
4. **Apply.** Dispatch `aws-apply.yml` with `root=authentik` and `apply=true`, and approve the `lab-write` job. The host boots and waits.
5. **Secrets and data.** Pedro runs `./scripts/seed-authentik-aws.sh --profile <profile> --copy-data` on the Mac. It writes the SSM parameters, copies the database and media while 119 keeps serving, and waits until `auth-aws.pdlab.dev` answers.
6. **Check.** Sign in at `https://auth-aws.pdlab.dev`. The lab copy is untouched.
7. **Switch.** Run step 5 again for a fresh copy, then merge the change that sets `authentik_side = "aws"` in `environments/homelab` and `accept_restore = false` here, and apply both. The record change takes about a minute.
8. **Lab side.** Point the LDAP outpost on 119 at `https://auth.pdlab.dev`, stop the server and worker there, and move the lab-verify, Kuma and Prometheus checks to the new names. Keep 119's database for a week as the rollback.

## Rollback

Set `authentik_side = "lab"` and start the server and worker on 119 again. Anything written on AWS after the switch stays on AWS until it is copied back.
