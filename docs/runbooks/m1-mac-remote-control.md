# Run the Mac's Remote Control server (PET-622)

The LaunchAgent `dev.pdlab.claude-remote` runs `claude remote-control` in `~/petedio` at
login. The server shows on the Claude app as `Mac`, and each session it spawns gets its own
git worktree. It is the macOS counterpart of `claude-ops-pm` on claude-247
(`roles/claude-code/templates/claude-ops-pm-serve.j2`) and of the Pete-AI server (`PET-621`).

| | |
|---|---|
| Wrapper | `scripts/m1-mac/claude-remote-serve.sh`, installed as a copy at `~/Library/Application Support/claude-remote/claude-remote-serve.sh` |
| Installer | `scripts/m1-mac/install-claude-remote.sh` |
| Agent | `~/Library/LaunchAgents/dev.pdlab.claude-remote.plist`, written by the installer |
| Folder | `~/petedio`, with `--spawn worktree` |
| Permission mode | `auto` |
| Logs | `~/Library/Logs/claude-remote/` |

## What the wrapper does

1. **Refuses to start until a person answers both prompts.** A server with no terminal hangs on
   a prompt, so the preflight reads `~/.claude.json` for the consent and the folder's trust.
2. **Runs one server per user.** If a `claude remote-control` process already runs, or another
   wrapper holds `serve.lock` in the log folder, the wrapper exits 0.
3. **Waits for DNS** to resolve `api.anthropic.com`, for up to 10 minutes.
4. **Holds off system sleep** with `caffeinate -s` while it runs. On AC power, an idle Mac
   stays awake. Closing the lid still sleeps it.
5. **Starts the server with `--spawn worktree`.** A plain start brings back every session the
   last server served, for about 4 hours after it stopped. The wrapper never passes
   `--continue`, which brings back only one session and can't be combined with `--spawn`.
6. **Stops a dead server's sessions.** Each server runs in its own process group. When the
   server exits, the wrapper logs and stops what is left in that group.
7. **Gives up visibly.** After 5 exits in 5 minutes, it exits 5, shows a macOS notification and
   sends a pete-bot DM. An expired login is the usual cause. launchd doesn't restart it.

## Set it up

To set the server up, run these steps in order.

1. **Answer the consent prompt.** To answer it, run the server once by hand:

   ```bash
   cd ~/petedio
   ```

   ```bash
   claude remote-control
   ```

   Answer `y`, wait for the session URL, then press Ctrl+C.

   > ⚠ Answer the prompt from a plain `claude remote-control` run. Don't try `--help` or
   > other flags first, because the consent prompt can hold any of them.

2. **Check the preflight.** It prints `preflight passed` or names what is missing:

   ```bash
   bash ~/petedio/iac/scripts/m1-mac/claude-remote-serve.sh --check
   ```

3. **Install the agent.** Run it as yourself, never with `sudo`:

   ```bash
   bash ~/petedio/iac/scripts/m1-mac/install-claude-remote.sh
   ```

   The installer copies the wrapper, runs the preflight, writes the plist and loads it. Then it
   reads back every setting, the copy's sha256 and launchd's record. Any mismatch exits 1.

4. **Verify it.** Open the Claude app on your phone. `Mac` appears under Remote Control. Then
   log out of the Mac, log back in, and check that `Mac` returns.

To update the wrapper after a change merges, pull `main` and run the installer again.

## Read the logs

| File | What writes it |
|---|---|
| `serve.log` | The wrapper: starts, exits, survivors, alerts and failures |
| `run-server.log` | The CLI's output from the last server |
| `claude-debug.log` | The CLI's `--debug-file` |
| `launchd.log` | Anything the wrapper prints before its own log opens |

To read launchd's record of the job, run:

```bash
launchctl print gui/$(id -u)/dev.pdlab.claude-remote
```

## Stop it, restart it or remove it

To stop the server until the next login, run:

```bash
launchctl bootout gui/$(id -u)/dev.pdlab.claude-remote
```

launchd sends SIGTERM to the wrapper, and the wrapper passes it to the server's process group.
To start it again, run the installer.

To remove the agent and its installed copy, run:

```bash
bash ~/petedio/iac/scripts/m1-mac/install-claude-remote.sh --uninstall
```

### Stop a stray session

A session process carries `--sdk-url` on its command line. The desktop app's and the
terminal's sessions match that pattern too, so list them before you stop one:

```bash
pgrep -fl -- '--sdk-url'
```

To stop one session, pass its pid to `kill`. Never run `pkill -f -- '--sdk-url'`: it also stops
the desktop app's sessions.

## After a give-up

The wrapper exits 5 and stays down until the next login or install. To recover:

1. Read `run-server.log`. A login error means you need to sign in again: run `claude` in a
   terminal and run `/login`.
2. Run the preflight with `--check`.
3. Run the installer.
