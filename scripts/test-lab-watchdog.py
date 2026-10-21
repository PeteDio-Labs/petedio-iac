#!/usr/bin/env python3
"""Test roles/lab-watchdog's probe (PET-707) without a Discord, a Kuma or a pete-bot.

The probe is a templated shell script, and each of its failure modes would pass a deploy
and still page nobody:

- a post that fails must exit non-zero, or the unit reads green over an alert never sent;
- one failed post must not stop another target's marker from being written, or the next
  cycle repeats a DOWN or drops a RECOVERED;
- the webhook URL must not reach curl's argv, where `ps` shows it.

It renders the real template, points it at a fake webhook that fails for chosen messages,
and runs it under a temp state directory. A curl shim on PATH records every argv.

Run:  python3 scripts/test-lab-watchdog.py     (needs python3-jinja2 and PyYAML)
"""
import os
import shlex
import subprocess
import sys
import tempfile

import jinja2
import yaml

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
ROLE = os.path.join(ROOT, "ansible", "roles", "lab-watchdog")
SECRET = "https://discord.com/api/webhooks/123/SECRET-TOKEN"

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else "  " + detail))
    if not ok:
        failures.append(name)


def render(targets, daily_hour=24):
    defaults = yaml.safe_load(open(os.path.join(ROLE, "defaults", "main.yml")))
    defaults["lab_watchdog_targets"] = targets
    defaults["lab_watchdog_daily_hour"] = daily_hour
    env = jinja2.Environment()
    env.filters["quote"] = shlex.quote
    return env.from_string(open(os.path.join(ROLE, "templates", "lab-watchdog.sh.j2")).read()).render(**defaults)


# The curl shim answers probes from a table in $LW_ANSWERS (url=code), and answers the
# webhook with failure when the body holds $LW_FAIL_MSG. It logs every argv to $LW_ARGV.
SHIM = r'''#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LW_ARGV"
url="${@: -1}"
case "$*" in *heartbeat*) [ -n "${LW_FAIL_BEAT:-}" ] && exit 22; exit 0 ;; esac
body=""; while [ $# -gt 0 ]; do case "$1" in -d) body="$2"; shift ;; esac; shift; done
if [ -n "$body" ]; then
  cat > /dev/null
  [ -n "${LW_FAIL_MSG:-}" ] && case "$body" in *"$LW_FAIL_MSG"*) exit 22 ;; esac
  exit 0
fi
grep -F "$url=" "$LW_ANSWERS" | head -1 | cut -d= -f2- | tr -d '\n'
'''


class Rig:
    def __init__(self, targets, daily_hour=24):
        self.tmp = tempfile.mkdtemp()
        t = self.tmp
        os.makedirs(os.path.join(t, "bin"))
        os.makedirs(os.path.join(t, "state"))
        shim = os.path.join(t, "bin", "curl")
        open(shim, "w").write(SHIM)
        os.chmod(shim, 0o755)
        script = render(targets, daily_hour)
        script = script.replace("STATE=/var/lib/lab-watchdog", "STATE=%s/state" % t)
        script = script.replace("HOOK_FILE=/etc/lab-watchdog/discord_webhook", "HOOK_FILE=%s/hook" % t)
        script = script.replace("BEAT_FILE=/etc/lab-watchdog/heartbeat", "BEAT_FILE=%s/heartbeat" % t)
        self.path = os.path.join(t, "lw.sh")
        open(self.path, "w").write(script)
        open(os.path.join(t, "hook"), "w").write(SECRET + "\n")
        self.answers = {}

    def run(self, answers, fail_msg="", *args, fail_beat=False):
        t = self.tmp
        with open(os.path.join(t, "answers"), "w") as f:
            for url, code in answers.items():
                f.write("%s=%s\n" % (url, code))
        env = dict(os.environ, PATH=os.path.join(t, "bin") + ":" + os.environ["PATH"],
                   LW_ANSWERS=os.path.join(t, "answers"), LW_ARGV=os.path.join(t, "argv"),
                   LW_FAIL_MSG=fail_msg, LW_FAIL_BEAT="1" if fail_beat else "")
        r = subprocess.run(["bash", self.path, *args], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return r

    def posts(self):
        p = os.path.join(self.tmp, "argv")
        lines = open(p).read().splitlines() if os.path.exists(p) else []
        return [ln for ln in lines if "-d " in ln]

    def argv_text(self):
        p = os.path.join(self.tmp, "argv")
        return open(p).read() if os.path.exists(p) else ""

    def marker(self, name):
        return os.path.exists(os.path.join(self.tmp, "state", name + ".posted"))


A, B = "http://a.test/", "http://b.test/"
TARGETS = [{"name": "alpha", "url": A, "ok": "200"}, {"name": "bravo", "url": B, "ok": "200"}]
DOWN = {A: "000", B: "000"}
UP = {A: "200", B: "200"}

# 1. Threshold: one failed run posts nothing; the second posts once per target.
r = Rig(TARGETS)
r.run(DOWN)
check("one failed run posts nothing", len(r.posts()) == 0)
res = r.run(DOWN)
check("second failed run posts once per target", len(r.posts()) == 2 and res.returncode == 0, res.stderr)
r.run(DOWN)
check("a third failed run does not repeat", len(r.posts()) == 2)

# 2. Recovery posts once and clears the marker.
res = r.run(UP)
check("recovery posts one line per recovered target", len(r.posts()) == 4 and not r.marker("alpha"))
r.run(UP)
check("a healthy run posts nothing", len(r.posts()) == 4)

# 3. A failed post exits non-zero, writes no marker, and the next run retries it.
r = Rig(TARGETS)
r.run(DOWN)
res = r.run(DOWN, fail_msg="DOWN: alpha")
check("a failed post exits non-zero", res.returncode != 0)
check("a failed post leaves its own marker unwritten", not r.marker("alpha"))
check("a successful post in the same run still writes its marker", r.marker("bravo"),
      "bravo's marker depends on alpha's failure (PET-707 review)")
res = r.run(DOWN)
check("the next run retries only the failed post", len(r.posts()) == 3 and res.returncode == 0)

# 4. The webhook URL never reaches argv, in a post or in --test.
res = r.run(UP, "", "--test")
check("--test posts", res.returncode == 0 and "posted" in res.stdout, res.stderr)
check("the webhook URL is absent from curl's argv", "SECRET-TOKEN" not in r.argv_text())

# 5. --check posts nothing and changes no state.
r = Rig(TARGETS)
r.run(DOWN, "", "--check")
r.run(DOWN, "", "--check")
check("--check posts nothing and writes no marker", len(r.posts()) == 0 and not r.marker("alpha"))

# 6. The daily line posts once a day and its marker follows its own post's result.
r = Rig(TARGETS, daily_hour=0)
r.run(UP)
r.run(UP)
check("the daily line posts once a day", len(r.posts()) == 1)
r = Rig(TARGETS, daily_hour=0)
res = r.run(UP, fail_msg="alive")
check("a failed daily post exits non-zero and retries", res.returncode != 0 and r.run(UP).returncode == 0)

# 7. The off-site heartbeat (PET-722): sent each run when configured, never by --check, and a
# failed beat exits non-zero without blocking alerts.
r = Rig(TARGETS)
open(os.path.join(r.tmp, "heartbeat"), "w").write('url = "https://beat.test/"\n')
r.run(UP)
check("a run sends the heartbeat", "heartbeat" in r.argv_text())
r = Rig(TARGETS)
open(os.path.join(r.tmp, "heartbeat"), "w").write('url = "https://beat.test/"\n')
r.run(UP, "", "--check")
check("--check sends no heartbeat", "heartbeat" not in r.argv_text())
r = Rig(TARGETS)
open(os.path.join(r.tmp, "heartbeat"), "w").write('url = "https://beat.test/"\n')
r.run(DOWN)
res = r.run(DOWN, "", fail_beat=True)
check("a failed heartbeat exits non-zero", res.returncode != 0)
check("a failed heartbeat still posts the DOWN alerts", len(r.posts()) == 2)
check("no heartbeat file means no beat and a clean exit",
      Rig(TARGETS).run(UP).returncode == 0)

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
