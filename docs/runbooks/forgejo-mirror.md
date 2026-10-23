# Runbook — the Forgejo read-only mirror on forgejo-249

> **Status: PET-756.** Terraform declares the host (`environments/homelab/forgejo.tf`). The play
> `ansible/playbooks/configure-forgejo-mirror.yml` installs Forgejo and the sync.

GitHub stays the source of truth. `forgejo-249` holds a copy of every `PeteDio-Labs` repo for
offline backup and fast LAN clones. Nothing pushes from the mirror back to GitHub.

## What runs where

| | |
|---|---|
| Host | `forgejo-249`, LXC 249 on pve03, `192.168.50.249` |
| Web and HTTP clone | `http://192.168.50.249:3000`. No SSH, no Cloudflare route, no port forward |
| Reach | The LAN, and the tailnet through pete-pi-1's `192.168.50.0/24` route |
| Forgejo | `/usr/local/bin/forgejo`, config `/etc/forgejo/app.ini`, data `/var/lib/forgejo` (SQLite) |
| Sync | `forgejo-mirror-sync.timer` every 30 minutes runs `/usr/local/bin/forgejo-mirror-sync` |
| Sync state | `/var/lib/forgejo-mirror/status.json` and bare caches under `cache/` |
| Credential | App `petedio-forgejo-mirror`, Contents and Metadata read-only, at `kv/services/forgejo-mirror` |

The sync does not use Forgejo's pull mirror. An App installation token lasts one hour, and a pull
mirror stores its credential in the remote URL. The script mints a token per run and keeps it in
a process environment. The Forgejo repos are ordinary repos that only the `mirror-sync` account
writes. A change pushed to one is overwritten on the next run.

## Pedro's steps (one time)

1. **Create the App.** Open `github.com/organizations/PeteDio-Labs/settings/apps/new`. Name it
   `petedio-forgejo-mirror`, turn webhooks off, set only Repository permissions Contents and
   Metadata to Read-only, and allow install on this account only.
2. **Generate a private key** on the App page, and **install** the App on `PeteDio-Labs` with
   **All repositories**.
3. **Seed Vault** from the Mac or 247:
   `./scripts/seed-forgejo-mirror-vault.sh --shred ~/Downloads/petedio-forgejo-mirror.*.private-key.pem`.
   The script refuses an App that can write, or an install on selected repositories.

## 247 steps

1. Merge the PET-756 PR. Apply-on-merge creates LXC 249. Confirm `forgejo_id = 249` in the apply log.
2. Run `./scripts/deploy-forgejo-mirror.sh`. The play fails unless the first sync examined the
   repos GitHub reported and synced each one.
3. Read the result: `ssh root@192.168.50.249 cat /var/lib/forgejo-mirror/status.json`. `examined`
   must equal `github_total`, and `failed` must be 0.

## Sign in

Registration is off. To add yourself as an admin, run on the host and write the printed password down once:

```bash
ssh root@192.168.50.249
runuser -u forgejo -- forgejo admin user create --admin --username petedillo \
  --email pedelgadillo@gmail.com --random-password --config /etc/forgejo/app.ini
```

## Clone from the mirror

Create an access token in Forgejo (Settings, Applications, scope `read:repository`), then:

```bash
git clone http://petedillo:<token>@192.168.50.249:3000/PeteDio-Labs/petedio-iac.git
```

Wire 247 and `petedio-search` to the mirror in a follow-up. Leave GitHub as `origin` for pushes.

## Check and repair

| Symptom | Check |
|---|---|
| Mirror is stale | `systemctl list-timers forgejo-mirror-sync.timer` and `journalctl -u forgejo-mirror-sync -n 50`; the log ends with `examined N of M GitHub repos` |
| `0 repositories` error | The App install lost its repos, or the key is revoked. Re-run the seed script |
| A new repo is missing | The install is not on All repositories. The seed script checks this |
| Rotate the key | Generate a new key, re-run the seed script, then the deploy script |
| Rebuild the host | Destroy and apply LXC 249, then run the deploy script. The mirror refills from GitHub |

Not copied: GitHub issues, pull requests, wikis, Actions secrets and LFS objects.
