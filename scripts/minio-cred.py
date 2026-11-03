#!/usr/bin/env python3
"""Print one value from a MinIO credential file (PET-789).

Usage: minio-cred.py FILE ROOT_USER|ROOT_PASSWORD

The file holds lines such as ROOT_USER=admin or MINIO_ROOT_USER=admin. The key matches at
the start of a line, with an optional `export` and an optional `MINIO_` prefix, and the
separator is `=` or `:`. The value is everything after the FIRST separator. The script
strips a trailing CR and one pair of surrounding quotes, and prints no newline.
Exit 1 when no line matches, so a missing key never reads as an empty value.
"""
import re
import sys


def read_cred(path, key):
    pattern = re.compile(
        r"^\s*(?:export\s+)?(?:MINIO_)?" + re.escape(key) + r"\s*[=:]\s*(.*)$", re.I)
    with open(path, encoding="utf-8") as fh:
        for line in fh.read().splitlines():
            m = pattern.match(line)
            if m:
                v = m.group(1)
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                return v
    return None


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    value = read_cred(sys.argv[1], sys.argv[2])
    if value is None:
        sys.exit(1)
    print(value, end="")
