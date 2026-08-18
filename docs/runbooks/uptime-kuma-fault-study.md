# Uptime Kuma on Pete-Pi — the fault-injection study instrument

Uptime Kuma on Pete-Pi is the measurement apparatus for a controlled
fault-injection study (PET-300). It is not general monitoring. Machine-readable
output — Prometheus metrics, status-page JSON, and the raw SQLite heartbeat
table — is the product; the dashboard is incidental.

To change anything here, edit `ansible/roles/uptime-kuma/` and re-run
`scripts/deploy-uptime-kuma.sh`. The monitor set is declarative in
`roles/uptime-kuma/defaults/main.yml` and the provisioner reconciles drift, so a
re-run is safe and is how you apply a change.

## Access

| | |
|---|---|
| UI | `http://192.168.50.4:3001` |
| Credentials | Vault `kv/services/uptime-kuma`, fields `admin_user` / `admin_password` |
| Credentials mirror | `security find-generic-password -s uptime-kuma-admin -a pete-pi -w` |
| Prometheus metrics | `http://192.168.50.4:3001/metrics` |
| Metrics auth | HTTP Basic, empty username, API key as password |
| Metrics key | Vault `kv/services/uptime-kuma` field `metrics_api_key` |
| Status page (JSON) | `http://192.168.50.4:3001/api/status-page/fault-study` |
| Status page heartbeats | `http://192.168.50.4:3001/api/status-page/heartbeat/fault-study` |
| Database | `/opt/uptime-kuma/data/kuma.db` on Pete-Pi |

The password is mirrored into the macOS Keychain deliberately. Sealing Vault is
one of the faults this study injects, and you need the monitoring UI most while
Vault is sealed. That is the same reasoning that keeps Vault's own unseal key in
the Keychain.

## The host

Pete-Pi is a Raspberry Pi 4 Model B on Debian 13 trixie, `aarch64`. It is
**outside the Proxmox cluster**, which is the point: the instrument keeps
recording while `pve01` or `pve02` is the thing being broken.

It is **dual-homed**, and both legs carry monitors:

- `eth0` `192.168.50.4` — default route, metric 100. The cluster, Vault, zot, ollama.
- `wlan0` `192.168.86.46` — metric 600. The only route to plex on `192.168.86.140`.

Neither path uses tailscale, so a tailnet outage cannot masquerade as a service
fault in the data.

> **The SSH aliases in `~/.ssh/config` are stale.** `pete-pi-1` (`192.168.86.25`)
> and `pete-pi-2` (`192.168.50.6`) are two aliases for this one machine, and both
> addresses are dead leases. There is no second Pi — a parallel SSH sweep of both
> `/24`s found exactly one. The working key is confusingly named
> `id_ed25519_pete_pi_2`; that is a naming artefact, not a second host. Log in as
> `pedro` (passwordless sudo), not `root`.

## Monitors

Every check runs at a **20-second interval with retries set to 1**, so the second
consecutive failure marks DOWN and a fault registers in about 40 seconds instead
of being smoothed away. Raw heartbeats are kept for **45 days**.

| Monitor | Type | Target |
|---|---|---|
| `zot-registry` | HTTP | `https://192.168.50.111/v2/_catalog` (TLS ignored) |
| `nfs-pve02` | TCP | `192.168.50.11:2049` |
| `vault` | HTTP | `https://192.168.50.223:8200/v1/sys/health` (TLS ignored) |
| `pve01` | TCP | `192.168.50.10:8006` |
| `pve02` | TCP | `192.168.50.11:8006` |
| `lidarr` | HTTP | `http://192.168.50.14:8686/` |
| `sonarr` | HTTP | `http://192.168.50.15:8989/` |
| `radarr` | HTTP | `http://192.168.50.16:7878/` |
| `prowlarr` | HTTP | `http://192.168.50.20:9696/` |
| `qbittorrent` | HTTP | `http://192.168.50.21:8080/` |
| `seerr` | HTTP | `http://192.168.50.33:5055/` |
| `plex` | HTTP | `http://192.168.86.140:32400/identity` |
| `ollama` | HTTP | `http://192.168.50.12:11434/api/version` |
| `dns-router` | DNS | `google.com` A via resolver `192.168.50.1:53` |

### Why these targets and not the obvious ones

**Raw IPs everywhere except `dns-router`.** A monitor that resolved a name would
go DOWN during an injected DNS fault and report a service outage that never
happened. Only the deliberate DNS monitor is allowed to depend on the resolver,
so a resolver failure moves exactly one line in the data.

**No public hostnames.** Anything behind Cloudflare Access answers 403 to a
non-browser client. Monitoring `docker.pdlab.dev` would have produced a permanent
false DOWN and poisoned the baseline before the study started.

**`zot-registry` and `nfs-pve02` are two monitors, never one.** zot's blob store
is an NFS mount from pve02, so stopping `nfs-server` on pve02 breaks a registry
running on pve01. Cause and symptom sit on different hosts, and that gap is the
object of study. The check uses `/v2/_catalog` rather than `/v2/` on purpose:
`_catalog` reads the storage layer, so the NFS fault actually surfaces, whereas
`/v2/` answers from memory and would stay green straight through the outage.

**`vault` accepts only 2xx.** `/v1/sys/health` answers 200 unsealed-active and
**503 sealed**, so restricting accepted codes to `200-299` maps a sealed Vault
onto DOWN — the wanted semantics, since sealing is an injected fault. HTTPS is
mandatory: the same path over plain HTTP returns a bare 400 that looks like a
broken server and is not.

**`plex` uses `/identity`.** The web root needs a token and answers 401.

## Pulling data

### Prometheus metrics

```bash
curl -s -u ":$(vault kv get -field=metrics_api_key kv/services/uptime-kuma)" http://192.168.50.4:3001/metrics
```

Unauthenticated requests get 401. The username is empty and the API key is the
password. Labels include `monitor_name`, so `monitor_status` and
`monitor_response_time` are directly usable per monitor.

### Response-time history for one monitor

`kuma-baseline` is installed on Pete-Pi at `/usr/local/bin/kuma-baseline`.

```bash
ssh pedro@192.168.50.4 "sudo kuma-baseline --monitor zot-registry --dump --from '2026-08-18 06:00:00' --to '2026-08-18 06:30:00'"
```

### Baseline, and whether a monitor has recovered

```bash
ssh pedro@192.168.50.4 "sudo kuma-baseline --all --baseline-mins 60 --recent-mins 5"
```

It reports `mean_ms`, `stdev_ms`, `p50_ms`, `p95_ms` and a 3-sigma band for the
pre-fault window, the same statistics for the current window, and a `recovered`
boolean. Exit status is 0 inside the band and 2 outside, so it can gate a wait
loop. Pass `--fault-start 'YYYY-MM-DD HH:MM:SS'` (UTC) to anchor the baseline
window immediately before a known injection.

### Which source to use for a baseline, and why

Use the **SQLite `heartbeat` table**. The other two surfaces cannot answer
"what was normal before the fault":

- **`/metrics`** is a gauge sampled at scrape time. It holds the current value
  and no history, so a baseline is only recoverable from it if something has
  been scraping it into a TSDB all along.
- **`/api/status-page/heartbeat/<slug>`** returns only the most recent beats per
  monitor — about 100, which at 20 seconds is roughly 33 minutes — and takes no
  time-range argument.
- **`heartbeat`** keeps every beat for the full 45-day retention with a
  timestamp and a `ping` in milliseconds, and accepts any range.

Times in the database are **UTC**: the container runs `TZ=UTC` so a DST boundary
cannot put a one-hour step inside a 30-day window.

## Backup to the HDD

The database lives on an SD card and Pete-Pi has no local disk — no USB device is
attached. At 14 monitors on a 20-second interval that is roughly 60,000 row
writes a day, and an SD failure mid-study takes the baseline with it.

pve02 already exports `/mnt/backups` (295 GB, 1% used) to the whole
`192.168.50.0/24`, so Pete-Pi mounts it with **no change to pve02**. A systemd
timer runs every 6 hours and writes `sqlite3 .backup` straight to the share.
Straight, because staging a copy on the SD card first would add exactly the
writes this is meant to spare.

```bash
ssh pete-pi "sudo systemctl start kuma-backup.service"   # run one now
ssh pete-pi "systemctl list-timers kuma-backup.timer"    # when the next one runs
ssh pve02 "ls -lt /mnt/backups/uptime-kuma/ | head"      # what actually landed
```

Backups are kept newest-30 and pruned automatically. The script asserts
`PRAGMA integrity_check` and non-zero monitor and heartbeat counts before keeping
a file, and deletes a backup that fails either — a liveness check is not a
correctness check, and `sqlite3` exits 0 having written a perfectly valid empty
database.

### What happens when pve02 is down

**Nothing is written, and nothing can be** — the backup target is a disk inside
pve02. The script checks with `findmnt` that the destination is genuinely an NFS
mount, refuses to write if it is not, exits 0, and the timer retries on the next
tick.

That refusal is load-bearing, not defensive padding. `fstab` only *generates* the
automount unit; it stays inactive until something starts it, and an inactive
automount leaves `/mnt/pve02-backups` as an ordinary directory **on the SD card**.
The first version of this backup wrote there and reported success — storing the
only copy on the disk it was meant to protect against. The role now starts the
automount unit explicitly, and the script will not write to a non-NFS path.

**A pve02 outage costs backup coverage, not data.** The live database keeps
recording the whole time because it is local to the Pi. Losing anything requires
the SD card to fail *inside* the same window. To close even that gap, run a
backup by hand after restoring pve02 — or add a second target that is not pve02
(all three `network-storage` volumes — `/mnt/backups`, `/mnt/shared`,
`/mnt/nexus-data` — live on pve02, so a fallback has to be MinIO on `.245` or
pve01's own export).

The mount is `noauto,x-systemd.automount,soft,timeo=50,retrans=2`: live only
while a backup runs, and an NFS outage returns `EIO` in about 10 seconds instead
of blocking in `D` state forever. That matters because this study breaks that
export on purpose.

> **The live `kuma.db` stays on the SD card, deliberately.** Moving it onto this
> share would stop the instrument recording during exactly the NFS and pve02
> faults it exists to measure.

## Persistence

The database is a bind mount at `/opt/uptime-kuma/data`, not a named volume, so
`sqlite3` on the host reads it without entering the container. Survival across
`docker compose down && up` was verified: the container ID changed, and all 14
monitors and the full heartbeat history remained.

Restart policy is `unless-stopped` and `docker.service` is enabled, so a reboot
brings the instrument back on its own. `unless-stopped` rather than `always` is
deliberate: a container you stop by hand mid-study stays stopped across a reboot
instead of silently resurrecting and writing beats you did not expect.
