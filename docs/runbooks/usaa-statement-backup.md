# Runbook — the USAA statement backup on minio-data-245

> **Status: live since 2026-09-10 (PET-393).** The bucket is declared in
> `ansible/inventory/group_vars/minio_data.yml` and converged by `roles/minio`.

Six years of bank statements and the SQLite database built from them live in one
directory on the Mac. This bucket is the second copy, and there is no third.

## Why git is not the safety net, deliberately

`usaa/.gitignore` excludes `*.pdf`, `*.db`, `*.db-journal` and `data/`, with the reason
written at the top of the file: *financial data never gets committed, scripts are
versioned, statements are not*. `petedio-iac` is public, so that rule is right and it
stays. The consequence is that a `git worktree remove --force` or a disk failure takes
the statements with it, and version control cannot help.

That is the shape of the 2026-09-03 rack loss. What made that outage survivable was
`ollama-backups` existing on a machine outside the cluster, not anything done afterwards.

## What is in the bucket

| | |
|---|---|
| Host | minio-data-245, `http://192.168.50.245:9000` — LAN and tailnet only, never public |
| Bucket | `usaa-statements`, **private**, versioned, 2 GiB hard quota |
| Layout | `data/pdf/<last4>/<from>_to_<to>.pdf`, plus `data/usaa.db` |
| Size | 220 objects, 49 MiB at first upload (2020-06-23 → 2026-07-31) |

Versioning is the recovery net for a bad re-ingest or an accidental `mc rm`. It is not a
second backup: it does not survive losing 245.

## Add new statements

`mirror` only sends what changed, so this is the same command every time.

```bash
mc mirror --overwrite ~/petedio/.claude/worktrees/usaa-statements-database-35994e/usaa/data \
  usaa245/usaa-statements/data
```

⚠ **Never `mc mirror --remove`.** It deletes objects absent from the source, which turns
a half-populated local directory into a deletion of the archive. Versioning would let you
undo it; do not rely on that.

## Restore

```bash
mc mirror usaa245/usaa-statements/data ./restored-data
```

Then **prove the restore rather than trusting the exit code** — the standing rule here is
that a service coming up healthy proves the process started, not that the data arrived:

```bash
# every object matches by content, not by count
( cd <source> && find data -type f -exec shasum -a 256 {} + | LC_ALL=C sort ) > /tmp/a
( cd <restored> && find data -type f -exec shasum -a 256 {} + | LC_ALL=C sort ) > /tmp/b
diff /tmp/a /tmp/b && echo "identical"

# the database opens, rather than merely existing
sqlite3 <restored>/data/usaa.db "select count(*) from sqlite_master where type='table';"
```

`LC_ALL=C sort` is load-bearing: two hosts collate differently, and without it a correct
transfer reports a false mismatch.

## The credential

Root credentials for 245 are at `kv/iac/minio-data-root` (fields `root_user`,
`root_password`) — referenced by name only. Resolve with
`scripts/pet-secrets get minio-data-root <field>`, and set the `mc` alias from the shell
rather than writing it to a file.

A bucket-scoped credential would be better than root here, the way
`reseed-minio-obsidian-vault.sh` mints one for the Obsidian bucket. It is not done yet.

## Related

`PET-392` — the pipeline's source is still un-versioned in a worktree, by decision.
`vault/Hosts/245-minio-data.md` — the host.
