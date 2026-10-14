# notify-pedro

The command a session runs to DM Pedro through pete-bot's `POST /v1/notify` (PET-584).
A pete-bot DM is the first way a session reaches him, so every session host carries it.

| Host | Playbook | Session users | Deploy script |
|---|---|---|---|
| claude-247 | `configure-claude-code.yml` | `claude`, and `claude-ops` when `claude_ops_enable` | `scripts/deploy-claude-247.sh` |
| codex-248 | `configure-codex.yml` | `codex` | `scripts/deploy-codex-248.sh` |

## Usage

```bash
notify-pedro "PET-584 is ready for your merge word"
notify-pedro --from claude-247-vault "Vault is sealed, and the 02:00 backup failed"
printf '%s\n' "a longer note" | notify-pedro -
notify-pedro --check
```

The sender defaults to `user@host`. A success prints the message id. `--check` proves the
token without sending a DM, and the role runs it for every user on every run.

| Exit | Meaning |
|---|---|
| 0 | Delivered, or `--check` passed |
| 1 | pete-bot refused the token or the message |
| 2 | Usage error, such as an empty or long message |
| 3 | pete-bot cannot be reached |

The role fails the run on exit 1, and warns on exit 3, because an outage on media-dash-237
is not this host's fault.

## The token

`kv/services/pete-bot` field `notify_bearer_token`. It opens `/v1/notify` alone, and pete-bot
refuses it on `/v1/alert`, so a session can DM Pedro and cannot post a fake monitor alert.
Each session user gets a 0400 copy at `~/.config/notify-pedro/token`.

To mint it, run `scripts/seed-pete-bot-notify-token.sh` from the Mac. To rotate it, run that
script with `--rotate`, then deploy pete-bot, then run each host's deploy script. Between the
pete-bot deploy and the host deploys, the hosts hold a token pete-bot refuses.

claude-247's dispatch-only workflow, `ansible-claude-247.yml`, carries no notify token,
because its Vault role cannot read `kv/services/pete-bot`, which holds the Discord token. A
run of that workflow leaves the copies on disk as they are.

## The network path

pete-bot listens on `192.168.50.237:3015`. codex-248's guest firewall rejects the LAN, so
`codex.tf` opens that one port above the reject.
