"""Off-site watchdog (PET-722).

Two entry paths in one function:

- a Function URL request is the lab's heartbeat: it must carry the heartbeat secret and
  records the time;
- a scheduled run checks the heartbeat's age and the public endpoints, and posts to Discord
  on a state change.

It posts DOWN after FAIL_THRESHOLD failed runs in a row, once, and RECOVERED when the target
answers. It posts one "alive" line a day and nothing else. Each marker follows its own post's
result, and a failed post raises so the invocation shows as an error. Standard library plus
boto3, which the Lambda runtime provides.
"""
import hmac
import json
import os
import socket
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

HEARTBEAT_ID = "heartbeat"
USER_AGENT = "DiscordBot (https://github.com/PeteDio-Labs/petedio-iac, 1)"  # Discord answers 403 to the default urllib agent
DISCORD_API = "https://discord.com/api/v10"


def _env(name, default=None):
    return os.environ.get(name, default)


class AwsStore:
    """DynamoDB for state, SSM for the secrets. Replaced by a fake in the tests."""

    def __init__(self):
        import boto3

        self._table = boto3.resource("dynamodb").Table(_env("TABLE"))
        self._ssm = boto3.client("ssm")
        self._cache = {}

    def get(self, key):
        item = self._table.get_item(Key={"id": key}).get("Item")
        return item

    def put(self, key, **fields):
        self._table.put_item(Item={"id": key, **fields})

    def secret(self, name):
        if name not in self._cache:
            self._cache[name] = self._ssm.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"]
        return self._cache[name]


def probe(check, timeout=8):
    """Return (code, cert_days). code is 0 when nothing answered. cert_days is None for HTTP."""
    code, days = 0, None
    req = urllib.request.Request(check["url"], headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            code = resp.status
    except urllib.error.HTTPError as err:
        code = err.code
    except (urllib.error.URLError, socket.timeout, ssl.SSLError, OSError):
        code = 0
    if check.get("min_cert_days") and check["url"].startswith("https://"):
        days = cert_days(check["url"], timeout)
    return code, days


def host_port(url):
    """The host and port a URL names, with 443 only when it names none."""
    parts = urllib.parse.urlsplit(url)
    return parts.hostname, parts.port or 443


def cert_days(url, timeout):
    host, port = host_port(url)
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as tls:
                not_after = ssl.cert_time_to_seconds(tls.getpeercert()["notAfter"])
        return int((not_after - time.time()) // 86400)
    except (OSError, ssl.SSLError, KeyError, ValueError):
        return None


def discord(target, text):
    """Post one message to the Lab-Agent DM as the bot. target is (bot token, DM channel id)."""
    token, channel = target
    req = urllib.request.Request(
        "%s/channels/%s/messages" % (DISCORD_API, channel),
        data=json.dumps({"content": text}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT,
                 "Authorization": "Bot " + token},
    )
    with urllib.request.urlopen(req, timeout=10):
        pass


def heartbeat(event, store, now):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    given = headers.get("x-heartbeat-secret", "")
    if not hmac.compare_digest(given, store.secret(_env("PARAM_HEARTBEAT"))):
        return {"statusCode": 403, "body": "forbidden"}
    store.put(HEARTBEAT_ID, ts=int(now))
    return {"statusCode": 200, "body": "ok"}


def run_checks(store, now, probe_fn=probe, post_fn=discord):
    target = (store.secret(_env("PARAM_DISCORD_TOKEN")), store.secret(_env("PARAM_DISCORD_CHANNEL")))
    threshold = int(_env("FAIL_THRESHOLD", "2"))
    max_age = int(_env("HEARTBEAT_MAX_AGE", "900"))
    checks = json.loads(_env("CHECKS", "[]"))
    failed_posts = []
    results = []  # (name, up, detail)

    # The first run arms the heartbeat, so a fresh deploy alerts max_age seconds later, not at once.
    beat = store.get(HEARTBEAT_ID)
    if beat is None:
        store.put(HEARTBEAT_ID, ts=int(now))
        beat = {"ts": int(now)}
    age = int(now) - int(beat["ts"])
    results.append(("lab-heartbeat", age <= max_age, "last heartbeat %d s ago" % age))

    def post(text):
        try:
            post_fn(target, text)
            return True
        except Exception as err:  # noqa: BLE001 - any failure to deliver is a failed post
            print("post failed: %s: %s" % (type(err).__name__, err))
            failed_posts.append(text)
            return False

    def process(name, up, detail):
        state = store.get("state#" + name) or {"fails": 0, "posted": False}
        fails, posted = int(state["fails"]), bool(state["posted"])
        if up:
            if posted and post("RECOVERED: %s answers again (%s). From AWS." % (name, detail)):
                posted = False
            fails = 0
        else:
            fails += 1
            if fails >= threshold and not posted and post(
                "DOWN: %s (%s), failed %d runs in a row. From AWS, outside the lab." % (name, detail, fails)
            ):
                posted = True
        store.put("state#" + name, fails=fails, posted=posted)

    # The heartbeat is judged and posted before any probe runs, so a slow public check can never
    # delay the alert that matters most.
    process(*results[0])

    # The probes run in parallel, so total time is one probe, not the sum of them.
    if checks:
        with ThreadPoolExecutor(max_workers=len(checks)) as pool:
            outcomes = list(pool.map(probe_fn, checks))
        for check, (code, days) in zip(checks, outcomes):
            up = code in check.get("ok", [200])
            detail = "status %s" % code
            if up and check.get("min_cert_days") and days is not None and days < check["min_cert_days"]:
                up, detail = False, "certificate expires in %d days" % days
            results.append((check["name"], up, detail))
            process(check["name"], up, detail)

    today = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d")
    hour = datetime.fromtimestamp(now, timezone.utc).hour
    daily = store.get("daily") or {"day": ""}
    if hour >= int(_env("DAILY_HOUR_UTC", "12")) and daily["day"] != today:
        answering = sum(1 for _, up, _ in results if up)
        if post("petedio-watchdog alive on AWS: %d of %d checks answering." % (answering, len(results))):
            store.put("daily", day=today)

    if failed_posts:
        raise RuntimeError("%d Discord post(s) failed" % len(failed_posts))
    return {"examined": len(results), "answering": sum(1 for _, up, _ in results if up)}


def handler(event, context, store=None, now=None):
    store = store or AwsStore()
    now = time.time() if now is None else now
    if "requestContext" in (event or {}) and "http" in event["requestContext"]:
        return heartbeat(event, store, now)
    return run_checks(store, now)
