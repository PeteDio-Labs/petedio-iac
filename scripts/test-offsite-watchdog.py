#!/usr/bin/env python3
"""Test environments/offsite-watchdog/lambda/handler.py (PET-722) without AWS or Discord.

The watchdog's failures are silent ones: a heartbeat that any caller can forge, a marker
written for a post that never arrived, a fresh deploy that pages at once, a missed
heartbeat that nobody hears. This drives the real handler against a fake store, a fake
probe and a fake Discord.

Run:  python3 scripts/test-offsite-watchdog.py
"""
import importlib.util
import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
spec = importlib.util.spec_from_file_location(
    "handler", os.path.join(ROOT, "environments", "offsite-watchdog", "lambda", "handler.py"))
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else "  " + detail))
    if not ok:
        failures.append(name)


class Store:
    def __init__(self):
        self.items = {}

    def get(self, key):
        return self.items.get(key)

    def put(self, key, **fields):
        self.items[key] = fields

    def secret(self, name):
        return {"/token": "bot-token", "/channel": "42", "/beat": "s3cret"}[name]


def configure(checks=()):
    os.environ.update(PARAM_DISCORD_TOKEN="/token", PARAM_DISCORD_CHANNEL="/channel", PARAM_HEARTBEAT="/beat", HEARTBEAT_MAX_AGE="900",
                      FAIL_THRESHOLD="2", DAILY_HOUR_UTC="12", CHECKS=json.dumps(list(checks)))


T0 = 1_800_000_000  # 2027-01-15 08:00 UTC, before the daily hour
posts, fail_on = [], []


def post_fn(target, text):
    if any(f in text for f in fail_on):
        raise OSError("discord unreachable")
    posts.append(text)


def run(store, now, probe_fn=lambda c: (200, None)):
    return h.run_checks(store, now, probe_fn=probe_fn, post_fn=post_fn)


# 1. Heartbeat auth.
configure()
s = Store()
ev = {"requestContext": {"http": {}}, "headers": {"X-Heartbeat-Secret": "wrong"}}
check("a wrong secret gets 403 and records nothing",
      h.handler(ev, None, store=s, now=T0)["statusCode"] == 403 and s.get("heartbeat") is None)
ev["headers"] = {}
check("no secret gets 403", h.handler(ev, None, store=s, now=T0)["statusCode"] == 403)
ev["headers"] = {"x-heartbeat-secret": "s3cret"}
check("the right secret records the time",
      h.handler(ev, None, store=s, now=T0)["statusCode"] == 200 and s.get("heartbeat")["ts"] == T0)

# 2. A fresh deploy arms the heartbeat and does not page.
s = Store()
run(s, T0)
run(s, T0 + 300)
check("a first run with no heartbeat posts nothing", posts == [])

# 3. A missed heartbeat pages once after the threshold, then recovers once.
s = Store()
s.put("heartbeat", ts=T0)
posts.clear()
run(s, T0 + 1000)  # age 1000 > 900: fail 1
check("one stale run posts nothing", posts == [])
run(s, T0 + 1300)  # fail 2
check("two stale runs post one DOWN", len(posts) == 1 and posts[0].startswith("DOWN: lab-heartbeat"))
run(s, T0 + 1600)
check("a third stale run does not repeat", len(posts) == 1)
s.put("heartbeat", ts=T0 + 1650)
run(s, T0 + 1700)
check("a fresh heartbeat posts RECOVERED once", len(posts) == 2 and posts[1].startswith("RECOVERED"))
run(s, T0 + 2000)
check("a healthy run posts nothing", len(posts) == 2)

# 4. A failed post raises, leaves its marker unset, and does not block another target's marker.
configure([{"name": "alpha", "url": "https://a.test/"}, {"name": "bravo", "url": "https://b.test/"}])
s = Store()
s.put("heartbeat", ts=T0)
posts.clear()
down = lambda c: (0, None)
run(s, T0 + 100, down)
fail_on[:] = ["DOWN: alpha"]
try:
    run(s, T0 + 200, down)
    raised = False
except RuntimeError:
    raised = True
check("a failed post raises", raised)
check("the failed post's marker stays unset", s.get("state#alpha")["posted"] is False)
check("another target's marker is still written", s.get("state#bravo")["posted"] is True)
fail_on.clear()
run(s, T0 + 300, down)
check("the next run retries only the failed post",
      [p for p in posts if p.startswith("DOWN: alpha")] != [] and
      len([p for p in posts if p.startswith("DOWN: bravo")]) == 1)

# 5. Certificate expiry reads as down.
configure([{"name": "tls", "url": "https://t.test/", "min_cert_days": 14}])
s = Store()
s.put("heartbeat", ts=T0)
posts.clear()
run(s, T0 + 10, lambda c: (200, 5))
run(s, T0 + 20, lambda c: (200, 5))
check("a certificate under the limit posts DOWN", len(posts) == 1 and "certificate expires in 5 days" in posts[0])

# 6. The daily line posts once a day, after the daily hour, and follows its own post.
configure()
s = Store()
noon = T0 + 4 * 3600 + 60
s.put("heartbeat", ts=noon)
posts.clear()
run(s, noon)
run(s, noon + 300)
check("the daily line posts once", len([p for p in posts if "alive" in p]) == 1)
s = Store()
s.put("heartbeat", ts=noon)
posts.clear()
fail_on[:] = ["alive"]
try:
    run(s, noon)
except RuntimeError:
    pass
fail_on.clear()
run(s, noon + 300)
check("a failed daily post is retried", len([p for p in posts if "alive" in p]) == 1)

# 7. The heartbeat alert goes out before any probe starts, and probes run in parallel.
configure([{"name": "slow%d" % i, "url": "https://s%d.test/" % i} for i in range(4)])
s = Store()
s.put("heartbeat", ts=T0)
s.put("state#lab-heartbeat", fails=1, posted=False)
posts.clear()
events = []
import threading
import time as _time
gate = threading.Barrier(4, timeout=5)


def slow_probe(c):
    events.append("probe-start:%d" % len(posts))
    gate.wait()  # all four must be in flight at once, or this raises
    return 0, None


run(s, T0 + 2000, slow_probe)
check("the heartbeat DOWN posts before any probe starts", events[0] == "probe-start:1", str(events))
check("probes run in parallel", len(events) == 4)

# 8. A certificate check uses the URL's own port.
check("host_port reads a nonstandard port", h.host_port("https://example.test:32400/x") == ("example.test", 32400))
check("host_port defaults to 443", h.host_port("https://example.test/x") == ("example.test", 443))

# 9. A post is a bot request into the DM channel: the URL, the Authorization header and a Discord
# User-Agent. Discord answers 403 to a request without them, and a 403 is a silent missed alert.
sent = []


class _Resp:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


h.urllib.request.urlopen = lambda req, timeout=None: sent.append(req) or _Resp()
h.discord(("bot-token", "42"), "hello")
req = sent[0]
check("the post goes to the DM channel's messages URL", req.full_url == "https://discord.com/api/v10/channels/42/messages", req.full_url)
check("the post carries the bot Authorization header", req.get_header("Authorization") == "Bot bot-token")
check("the post carries a DiscordBot User-Agent", req.get_header("User-agent", "").startswith("DiscordBot ("))
check("the post body is the message", json.loads(req.data) == {"content": "hello"})

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
