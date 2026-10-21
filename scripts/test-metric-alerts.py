#!/usr/bin/env python3
"""Test roles/metric-alerts' evaluator (PET-708) without a Prometheus or a Discord.

The failures this guards against are silent ones: a rule that reads an empty store as "all well", a
marker written for a post that never arrived, a RESOLVED posted for something that never fired, and a
bot token in curl's argv. It drives the real script against a fake store, a fake post and, for the
end-to-end cases, a local HTTP server and a curl shim.

Run:  python3 scripts/test-metric-alerts.py
"""
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SCRIPT = os.path.join(ROOT, "ansible", "roles", "metric-alerts", "files", "metric-alerts.py")
spec = importlib.util.spec_from_file_location("metric_alerts", SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else "  " + detail))
    if not ok:
        failures.append(name)


def series(host, value="0.9"):
    return {"metric": {"host": host, "job": "node", "instance": host + ":9100"}, "value": [0, value]}


RULES = [{"name": "disk-full", "summary": "Root is over 85 percent", "expr": "x", "for_runs": 3}]
posts = []


def fake_post(text):
    posts.append(text)
    return True


def run(state, result, rules=RULES, post_fn=fake_post, mode="run", fail=False):
    def query_fn(expr):
        if fail:
            raise OSError("store down")
        return result
    return m.evaluate(rules, state, query_fn=query_fn, post_fn=post_fn, mode=mode)


# 1. A series posts only after for_runs consecutive runs, and only once.
state = {}
for _ in range(2):
    rc, _, state = run(state, [series("a")])
check("no post before for_runs", posts == [], str(posts))
rc, _, state = run(state, [series("a")])
check("one post at for_runs", len(posts) == 1 and posts[0].startswith("FIRING: Root is over 85 percent (host=a)"), str(posts))
rc, _, state = run(state, [series("a")])
check("no second post while it keeps firing", len(posts) == 1)

# 2. It posts RESOLVED once, and nothing for a series that never posted.
rc, _, state = run(state, [])
check("RESOLVED posts once", len(posts) == 2 and posts[1].startswith("RESOLVED"), str(posts))
rc, _, state = run(state, [])
check("no second RESOLVED", len(posts) == 2)
posts.clear()
state = {}
rc, _, state = run(state, [series("b")])
rc, _, state = run(state, [])
check("a series that never posted resolves silently", posts == [] and state == {}, str(state))

# 3. A failed post leaves its marker unset, and the next run retries.
posts.clear()
calls = []


def flaky(text):
    calls.append(text)
    return len(calls) > 1


state = {"disk-full{host=a}": {"runs": 2, "posted": False}}
rc, _, state = run(state, [series("a")], post_fn=flaky)
check("a failed post exits non-zero", rc == 1)
check("a failed post leaves the marker unposted", state["disk-full{host=a}"]["posted"] is False)
rc, _, state = run(state, [series("a")], post_fn=flaky)
check("the next run retries and succeeds", rc == 0 and state["disk-full{host=a}"]["posted"] is True)

# 4. A failed RESOLVED post keeps the marker, so it retries.
state = {"disk-full{host=a}": {"runs": 5, "posted": True}}
rc, _, state = run(state, [], post_fn=lambda t: False)
check("a failed RESOLVED keeps the marker", rc == 1 and state.get("disk-full{host=a}", {}).get("posted") is True, str(state))

# 5. A failed query proves nothing: counters stay and nothing resolves.
posts.clear()
state = {"disk-full{host=a}": {"runs": 5, "posted": True}}
rc, lines, state = run(state, [], fail=True)
check("a failed query exits non-zero", rc == 1)
check("a failed query keeps the posted marker and posts nothing", state.get("disk-full{host=a}", {}).get("posted") is True and posts == [], str(posts))

# 6. Every query failing means the store is down: post once, then RESOLVED when it answers.
posts.clear()
state = {}
rc, _, state = run(state, [], fail=True)
check("one failed run does not post the store alert", posts == [])
rc, _, state = run(state, [], fail=True)
check("two failed runs post the store alert once", len(posts) == 1 and "answers no query" in posts[0], str(posts))
rc, _, state = run(state, [], fail=True)
check("no second store alert", len(posts) == 1)
rc, _, state = run(state, [])
check("the store alert resolves once it answers", len(posts) == 2 and posts[1].startswith("RESOLVED: the metrics store"), str(posts))

# 7. --check posts nothing.
posts.clear()
rc, _, new = run({}, [series("a")], rules=[dict(RULES[0], for_runs=1)], mode="check")
check("--check posts nothing", posts == [])

# 7b. The coverage rule must fire on an empty store. count() over nothing returns nothing, so the
# shipped expression needs `or vector(0)`. The evaluator side: the series that `vector(0) < 15`
# returns has no labels, and the evaluator must treat it as one firing series.
import yaml  # noqa: E402

with open(os.path.join(ROOT, "ansible", "roles", "metric-alerts", "defaults", "main.yml")) as fh:
    shipped = yaml.safe_load(fh)["metric_alerts_rules"]
coverage = [r for r in shipped if r["name"] == "coverage"]
check("the shipped coverage rule exists", len(coverage) == 1)
check("the coverage rule falls back to vector(0) so an empty store fires",
      bool(coverage) and "or vector(0)" in coverage[0]["expr"], coverage[0]["expr"] if coverage else "")
bare = [r["name"] for r in shipped if "count(" in r["expr"] and "< " in r["expr"] and "vector(0)" not in r["expr"]]
check("no count()-below-threshold rule lacks the empty-store fallback", bare == [], str(bare))
posts.clear()
empty_label = {"metric": {}, "value": [0, "0"]}
cov_rule = [dict(coverage[0], for_runs=1)] if coverage else RULES
rc, _, state = run({}, [empty_label], rules=cov_rule)
check("an empty-label series (zero exporters) posts FIRING", len(posts) == 1 and posts[0].startswith("FIRING"), str(posts))
rc, lines, _ = run({}, [], rules=cov_rule)
check("a rule that returns nothing prints how many it examined", any("examined, 0 firing" in l for l in lines), str(lines))

# 8. End to end: a local store, a curl shim, and the real script. The token must stay out of argv.
answers = {"result": [series("e2e")]}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"status": "success", "data": {"resultType": "vector", "result": answers["result"]}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
tmp = tempfile.mkdtemp()
os.makedirs(os.path.join(tmp, "bin"))
shim = os.path.join(tmp, "bin", "curl")
open(shim, "w").write('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$SHIM_ARGV"\n'
                      'prev=""; for a in "$@"; do [ "$prev" = "-K" ] && cat "$a" >> "$SHIM_CFG"; prev="$a"; done\nexit 0\n')
os.chmod(shim, os.stat(shim).st_mode | stat.S_IEXEC)
open(os.path.join(tmp, "rules.json"), "w").write(json.dumps([dict(RULES[0], for_runs=1)]))
open(os.path.join(tmp, "discord.curl"), "w").write('url = "https://discord.test/x"\nheader = "Authorization: Bot SECRET-TOKEN"\n')
env = dict(os.environ, PATH=os.path.join(tmp, "bin") + ":" + os.environ["PATH"],
           METRIC_ALERTS_PROM="http://127.0.0.1:%d" % server.server_port,
           METRIC_ALERTS_RULES=os.path.join(tmp, "rules.json"), METRIC_ALERTS_STATE=os.path.join(tmp, "state.json"),
           METRIC_ALERTS_DISCORD=os.path.join(tmp, "discord.curl"),
           SHIM_ARGV=os.path.join(tmp, "argv"), SHIM_CFG=os.path.join(tmp, "cfg"))
r = subprocess.run([sys.executable, SCRIPT], env=env, capture_output=True, text=True)
argv = open(os.path.join(tmp, "argv")).read() if os.path.exists(os.path.join(tmp, "argv")) else ""
check("the real script exits 0 and posts through curl", r.returncode == 0 and "FIRING" in argv, r.stdout + r.stderr + argv)
check("the bot token is absent from curl's argv", "SECRET-TOKEN" not in argv)
check("curl reads the Discord config through -K", "-K " in argv and "SECRET-TOKEN" in open(os.path.join(tmp, "cfg")).read())
check("the state file records the posted series", json.load(open(os.path.join(tmp, "state.json")))["disk-full{host=e2e}"]["posted"] is True)
r = subprocess.run([sys.executable, SCRIPT, "--check"], env=env, capture_output=True, text=True)
check("--check exits 0 and prints the examined count", r.returncode == 0 and "examined 1 rules" in r.stdout, r.stdout)
os.remove(os.path.join(tmp, "argv"))
subprocess.run([sys.executable, SCRIPT], env=env, capture_output=True, text=True)
check("a second run posts nothing while it keeps firing", not os.path.exists(os.path.join(tmp, "argv")))
server.shutdown()

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
