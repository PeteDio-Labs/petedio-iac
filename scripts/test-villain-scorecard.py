#!/usr/bin/env python3
"""Tests for scripts/villain/scorecard.py (PET-954). Offline; run: python3 scripts/test-villain-scorecard.py"""
import json, subprocess, sys, tempfile, unittest
from pathlib import Path

S = Path(__file__).resolve().parent / "villain" / "scorecard.py"
STATUS = {"publicGroupList": [{"monitorList": [{"id": 7, "name": "decoy-dc-251"}, {"id": 8, "name": "sonarr"}]}]}


def run(beats, victims="251", *extra):
    with tempfile.TemporaryDirectory() as d:
        a, b = Path(d, "s.json"), Path(d, "b.json")
        a.write_text(json.dumps(STATUS)); b.write_text(json.dumps({"heartbeatList": beats}))
        p = subprocess.run([sys.executable, str(S), "--since", "2026-11-26T15:00:00Z", "--victims", victims,
                            "--status-file", str(a), "--beats-file", str(b), *extra], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def beat(t, s):
    return {"time": f"2026-11-26 {t}", "status": s}


class T(unittest.TestCase):
    def test_detects_and_recovers(self):
        rc, out = run({"7": [beat("14:59:40", 1), beat("15:00:20", 0), beat("15:01:00", 1)]},
                      "251", "--undo-at", "2026-11-26T15:00:40Z")
        self.assertEqual(rc, 0); self.assertIn("DOWN after 20 s", out); self.assertIn("UP again 20 s", out)

    def test_undo_without_recovery_fails(self):
        rc, out = run({"7": [beat("15:00:20", 0), beat("15:01:00", 0)]}, "251", "--undo-at", "2026-11-26T15:00:40Z")
        self.assertEqual(rc, 1); self.assertIn("no UP beat after the undo", out)

    def test_no_undo_given_and_still_down_is_not_a_failure(self):
        rc, out = run({"7": [beat("15:00:20", 0)]})
        self.assertEqual(rc, 0); self.assertIn("not yet UP", out)

    def test_empty_victim_list_fails(self):
        for v in ("", ","):
            rc, out = run({"7": [beat("15:00:20", 0)]}, v)
            self.assertEqual(rc, 1); self.assertIn("named no victim", out)

    def test_never_down_fails(self):
        rc, out = run({"7": [beat("15:00:20", 1), beat("15:01:00", 1)]})
        self.assertEqual(rc, 1); self.assertIn("never seen DOWN", out)

    def test_zero_beats_fails_and_says_so(self):
        rc, out = run({})
        self.assertEqual(rc, 1); self.assertIn("0 beats", out)

    def test_missing_monitor_fails(self):
        rc, out = run({"7": [beat("15:00:20", 0)]}, "252")
        self.assertEqual(rc, 1); self.assertIn("no Kuma monitor", out)

    def test_discord_no_fails(self):
        rc, out = run({"7": [beat("15:00:20", 0)]}, "251", "--discord", "no")
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main()
