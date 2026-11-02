#!/usr/bin/env python3
"""Test the MinIO credential-file parser that seed-minio-221.sh uses (PET-789).

Run:  python3 scripts/test-minio-cred.py
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CRED = os.path.join(HERE, "minio-cred.py")

CASES = {
    "bare names": ("ROOT_USER=alice\nROOT_PASSWORD=p=w:d\n", "alice", "p=w:d"),
    "MinIO env names": ("MINIO_ROOT_USER=alice\nMINIO_ROOT_PASSWORD=pw\n", "alice", "pw"),
    "export, colon, quotes, CRLF": (
        'export MINIO_ROOT_USER: "alice"\r\nexport MINIO_ROOT_PASSWORD = \'pw\'\r\n', "alice", "pw"),
    "other keys ignored": (
        "CI_MINIO_ROOT_USER=ci\nMINIO_ROOT_USER=alice\nMINIO_ROOT_PASSWORD=pw\n", "alice", "pw"),
}

fail = 0


def run(path, key):
    return subprocess.run([sys.executable, "-I", CRED, path, key], capture_output=True, text=True)


with tempfile.TemporaryDirectory() as d:
    for name, (body, user, pw) in CASES.items():
        path = os.path.join(d, "creds.txt")
        with open(path, "w", newline="") as fh:
            fh.write(body)
        got = (run(path, "ROOT_USER").stdout, run(path, "ROOT_PASSWORD").stdout)
        ok = got == (user, pw)
        fail += not ok
        print(("ok   " if ok else "FAIL ") + name + ("" if ok else f" got lengths {[len(g) for g in got]}"))
    path = os.path.join(d, "none.txt")
    with open(path, "w") as fh:
        fh.write("SOMETHING_ELSE=1\n")
    r = run(path, "ROOT_USER")
    ok = r.returncode == 1 and r.stdout == ""
    fail += not ok
    print(("ok   " if ok else "FAIL ") + "missing key exits 1 with no output")

print(f"{fail} failed" if fail else "all passed")
sys.exit(1 if fail else 0)
