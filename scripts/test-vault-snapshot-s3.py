#!/usr/bin/env python3
"""test-vault-snapshot-s3 — prove the vault-snapshot script talks S3 without mc (PET-800).

Renders ansible/roles/vault-snapshot/templates/vault-snapshot.sh.j2, runs it with a stub
`vault` and the real `curl`, and points it at a local fake S3 server. The server recomputes
each AWS Signature V4 signature from the request and compares it, so a malformed signature
fails the test the way MinIO would reject it. It also checks the body against the signed
payload hash.

    python3 scripts/test-vault-snapshot-s3.py

Contacts nothing outside 127.0.0.1. Needs python3, jinja2, bash and curl 7.75 or later.
It checks the script's S3 logic, not MinIO itself: the live proof is the Mac rerun of
PET-790 step 3.
"""
import hashlib, hmac, os, shutil, stat, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit, parse_qsl, quote

import jinja2

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(ROOT, "ansible/roles/vault-snapshot/templates/vault-snapshot.sh.j2")
AK, SK, REGION, BUCKET = "AKTESTKEY", "sk-test-secret-value-9f3a", "us-east-1", "vault-snapshots"
SNAP_BYTES = b"RAFT-SNAPSHOT-" + os.urandom(4096)

PASS = FAIL = 0
def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1; print(f"  ok   {name}")
    else:
        FAIL += 1; print(f"  FAIL {name} {detail}")


def _sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def sigv4_ok(method, path, query, headers, secret):
    """Recompute the SigV4 signature of a request; True if it matches the one sent."""
    auth = headers.get("Authorization", "")
    if not auth.startswith("AWS4-HMAC-SHA256 "):
        return False, "no AWS4 Authorization header"
    parts = dict(p.strip().split("=", 1) for p in auth[len("AWS4-HMAC-SHA256 "):].split(","))
    signed = parts["SignedHeaders"].split(";")
    scope = parts["Credential"].split("/", 1)[1]            # date/region/service/aws4_request
    canon_headers = "".join(f"{h}:{' '.join(headers[h].split())}\n" for h in signed)
    qs = "&".join(f"{quote(k, safe='')}={quote(v, safe='')}" for k, v in sorted(parse_qsl(query, keep_blank_values=True)))
    payload = headers.get("x-amz-content-sha256", "")
    canon = "\n".join([method, quote(path, safe="/-_.~"), qs, canon_headers, parts["SignedHeaders"], payload])
    amzdate = headers["x-amz-date"]
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amzdate, scope, hashlib.sha256(canon.encode()).hexdigest()])
    k = ("AWS4" + secret).encode()
    for piece in scope.split("/"):
        k = _sign(k, piece)
    want = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    return want == parts["Signature"], "signature mismatch"


def make_server(mode):
    store, log = {}, []

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def _reply(self, code, body=b"", extra=None):
            self.send_response(code)
            self.send_header("Content-Length", str(len(body) if "len" not in (extra or {}) else extra["len"]))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
        def _handle(self):
            u = urlsplit(self.path)
            hdrs = {k.lower() if k.lower().startswith("x-amz") or k.lower() in ("host", "content-length", "content-type") else k: v
                    for k, v in self.headers.items()}
            hdrs = {k.lower() if k.lower() != "authorization" else "Authorization": v for k, v in hdrs.items()}
            body = self.rfile.read(int(self.headers.get("Content-Length", 0))) if self.command == "PUT" else b""
            ok, why = sigv4_ok(self.command, u.path, u.query, hdrs, SK)
            log.append((self.command, u.path, ok))
            if not ok:
                return self._reply(403)
            if u.path.rstrip("/") == f"/{BUCKET}":
                return self._reply(404 if mode == "nobucket" else 200, b"<ListBucketResult/>")
            if self.command == "PUT":
                if hashlib.sha256(body).hexdigest() != hdrs.get("x-amz-content-sha256"):
                    return self._reply(400)
                store[u.path] = body
                return self._reply(200)
            if self.command == "HEAD" and u.path in store:
                n = len(store[u.path]) - (1 if mode == "truncate" else 0)
                return self._reply(200, extra={"len": n})
            self._reply(404)
        do_GET = do_PUT = do_HEAD = _handle

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, store, log


def run_case(mode, secret=SK, port=None):
    tmp = tempfile.mkdtemp()
    try:
        srv, store, log = make_server(mode)
        hostport = f"127.0.0.1:{port or srv.server_port}"
        env = jinja2.Environment(undefined=jinja2.StrictUndefined)
        env.filters["regex_replace"] = lambda s, a, b: __import__("re").sub(a, b, s)
        for n in ("role_id", "secret_id"):
            open(f"{tmp}/{n}", "w").write("x")
        script = env.from_string(open(TEMPLATE).read()).render(
            ansible_managed="test", vault_snapshot_vault_addr="https://127.0.0.1:1",
            vault_snapshot_vault_cacert=f"{tmp}/ca", vault_snapshot_role_id_file=f"{tmp}/role_id",
            vault_snapshot_secret_id_file=f"{tmp}/secret_id", vault_snapshot_local_dir=f"{tmp}/snaps",
            vault_snapshot_retain_local=2, vault_snapshot_minio_region=REGION,
            vault_snapshot_minio_scheme="http", vault_snapshot_minio_hostport=hostport,
            vault_snapshot_bucket=BUCKET, vault_snapshot_minio_creds_path="kv/data/services/vault-snapshots")
        open(f"{tmp}/run.sh", "w").write(script)
        os.mkdir(f"{tmp}/bin")
        real_curl = shutil.which("curl")
        # vault stub: records that a snapshot was taken; serves the creds by reference.
        open(f"{tmp}/bin/vault", "w").write(f"""#!/usr/bin/env bash
case "$*" in
  "write -field=token"*) echo tok ;;
  "kv get -field=access_key"*) echo {AK} ;;
  "kv get -field=secret_key"*) echo {secret} ;;
  "operator raft snapshot save"*) touch {tmp}/snapshot-taken; cat {tmp}/payload >"$5" ;;
  *) echo "unexpected vault $*" >&2; exit 9 ;;
esac
""")
        open(f"{tmp}/payload", "wb").write(SNAP_BYTES)
        # curl wrapper: records argv so the test can prove no secret reached it.
        open(f"{tmp}/bin/curl", "w").write(f'#!/usr/bin/env bash\necho "$*" >>{tmp}/curl-argv\nexec {real_curl} "$@"\n')
        for n in ("vault", "curl"):
            os.chmod(f"{tmp}/bin/{n}", 0o755)
        p = subprocess.run(["bash", f"{tmp}/run.sh"], capture_output=True, text=True,
                           env={"PATH": f"{tmp}/bin:/usr/bin:/bin", "HOME": tmp}, timeout=60)
        argv = open(f"{tmp}/curl-argv").read() if os.path.exists(f"{tmp}/curl-argv") else ""
        return p, store, log, argv, os.path.exists(f"{tmp}/snapshot-taken")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


print("happy path")
p, store, log, argv, taken = run_case("ok")
check("exit 0", p.returncode == 0, p.stderr)
check("every request carried a valid SigV4 signature", log and all(ok for _, _, ok in log), str(log))
check("bucket checked, then object PUT, then read back (GET, PUT, HEAD)", [m for m, _, _ in log] == ["GET", "PUT", "HEAD"], str(log))
check("MinIO holds the exact snapshot bytes", list(store.values()) == [SNAP_BYTES])
check("log line names the object, its size and sha256", "bytes, sha256" in p.stdout, p.stdout)
check("secret key never reaches curl argv, stdout or stderr", SK not in argv + p.stdout + p.stderr)
check("access key never reaches curl argv", AK not in argv)

print("bucket missing")
p, store, log, argv, taken = run_case("nobucket")
check("exit non-zero", p.returncode != 0)
check("error names HTTP 404 and the bucket", "HTTP 404" in p.stderr and BUCKET in p.stderr, p.stderr)
check("no snapshot taken before the precondition failed", not taken)

print("wrong secret")
p, store, log, argv, taken = run_case("ok", secret="not-the-key")
check("exit non-zero with HTTP 403", p.returncode != 0 and "HTTP 403" in p.stderr, p.stderr)
check("no snapshot taken", not taken)

print("read-back size differs")
p, store, log, argv, taken = run_case("truncate")
check("exit non-zero and names the size mismatch", p.returncode != 0 and "reads back" in p.stderr, p.stderr)

print("endpoint unreachable")
p, store, log, argv, taken = run_case("ok", port=1)
check("exit non-zero with HTTP 000", p.returncode != 0 and "HTTP 000" in p.stderr, p.stderr)
check("no snapshot taken", not taken)

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
