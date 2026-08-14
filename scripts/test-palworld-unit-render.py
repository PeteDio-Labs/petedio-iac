#!/usr/bin/env python3
"""Render palworld.service.j2 the way Ansible actually does and assert the unit is sane.

WHY: a template that renders wrong still writes cleanly, and systemd loads a malformed
ExecStart without complaint — Palworld ignores unknown args, so the server comes up green.
That shipped once: Ansible sets trim_blocks=True, which ate the newline after a block tag and
produced `ExecStart=... -enable-gamedata-apiRestart=on-failure` — no GameData API, no Restart=
directive, nothing failing anywhere.

Run:  python3 scripts/test-palworld-unit-render.py
The role asserts the same properties against the DEPLOYED file; this catches it before then.
"""
import os
import re
import sys

try:
    from jinja2 import Environment, FileSystemLoader
except ImportError:
    print("SKIP: jinja2 not installed (pip install jinja2)")
    raise SystemExit(0)

TEMPLATE_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "ansible", "roles", "palworld", "templates"
)

env = Environment(loader=FileSystemLoader(TEMPLATE_DIR), trim_blocks=True,
                  lstrip_blocks=False, keep_trailing_newline=True)
# `bool` is an ANSIBLE filter, not a stock Jinja2 one. Emulate it so this test exercises the
# template exactly as production does, rather than forcing the template to drop a filter that
# is correct there.
def _bool(v):
    if isinstance(v, bool):
        return v
    return str(v).strip().lower() in ("true", "yes", "on", "1")

env.filters["bool"] = _bool
tpl = env.get_template("palworld.service.j2")

base = dict(
    palworld_server_exec="/home/steam/palworld/PalServer.sh",
    palworld_server_dir="/home/steam/palworld",
    palworld_user="steam",
    palworld_service_name="palworld",
    palworld_rest_api_port=8212,
)

fail = False
for enabled in (True, False):
    out = tpl.render(**base, palworld_gamedata_api_enabled=enabled)
    exec_line = [l for l in out.splitlines() if l.startswith("ExecStart=")][0]
    has_restart = bool(re.search(r"(?m)^Restart=", out))
    has_restartsec = bool(re.search(r"(?m)^RestartSec=", out))
    flag_ok = exec_line.endswith(" -enable-gamedata-api") == enabled
    clean = "Restart=" not in exec_line
    print("enabled=%s" % enabled)
    print("  %s" % exec_line)
    print("  ^Restart=%s ^RestartSec=%s flag_ok=%s clean_execstart=%s"
          % (has_restart, has_restartsec, flag_ok, clean))
    if not (has_restart and has_restartsec and flag_ok and clean):
        fail = True

print("RESULT: " + ("FAILED" if fail else "both renders OK"))
raise SystemExit(1 if fail else 0)
