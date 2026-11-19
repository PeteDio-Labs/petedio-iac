#!/usr/bin/env python3
"""Tests for scripts/villain/guard.py (PET-954). Offline; run: python3 scripts/test-villain-guard.py"""
import subprocess, sys, tempfile, unittest
from pathlib import Path

G = Path(__file__).resolve().parent / "villain" / "guard.py"
NOON = "2026-11-19T12:00:00-05:00"


def run(rows, *args, now=NOON):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write("\n".join(rows) + "\n")
    p = subprocess.run([sys.executable, str(G), "check", *args, "--targets", f.name, "--now", now],
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


GOTHAM = [f"dc {900+i} gotham-{i} pve03 decoy" for i in range(1, 5)]
MARVEL = [f"marvel {950+i} titan-{i} pve03 decoy" for i in range(1, 5)]


class T(unittest.TestCase):
    def test_empty_list_refuses(self):
        rc, out = run([], "joker")
        self.assertEqual(rc, 1); self.assertIn("no usable targets", out)

    def test_joker_picks_one_and_is_replayable(self):
        a = run(GOTHAM, "joker", "--seed", "7"); b = run(GOTHAM, "joker", "--seed", "7")
        self.assertEqual(a, b); self.assertEqual(a[1].count("victim "), 1)

    def test_thanos_takes_half_rounded_down(self):
        rc, out = run(MARVEL, "thanos", "--seed", "1")
        self.assertEqual(rc, 0); self.assertEqual(out.count("victim "), 2)
        rc, out = run(MARVEL[:3], "thanos", "--seed", "1")
        self.assertEqual(out.count("victim "), 1)

    def test_thanos_refuses_group_of_one_and_missing_group(self):
        self.assertEqual(run(GOTHAM[:1], "thanos", "--group", "dc")[0], 1)
        self.assertEqual(run(MARVEL[:1], "thanos")[0], 1)

    def test_thanos_snaps_half_of_marvel_only(self):
        rc, out = run(GOTHAM + MARVEL, "thanos", "--seed", "3")
        self.assertEqual(rc, 0); self.assertEqual(out.count("victim "), 2)
        self.assertNotIn("gotham-", out)

    def test_joker_stays_in_dc(self):
        rc, out = run(GOTHAM + MARVEL, "joker", "--seed", "5")
        self.assertIn("gotham-", out); self.assertNotIn("titan-", out)

    def test_denylist_and_tier(self):
        rc, out = run(["core 223 vault pve03 decoy", "core 250 x pve03 prod"], "joker")
        self.assertEqual(rc, 1); self.assertIn("denied 2", out)

    def test_quiet_hours(self):
        rc, out = run(GOTHAM, "joker", now="2026-11-19T02:45:00-05:00")
        self.assertEqual(rc, 1); self.assertIn("quiet hours", out)

    def test_dry_run_says_kill_switch_state(self):
        rc, out = run(GOTHAM, "joker", "--seed", "1")
        self.assertIn("would be refused", out); self.assertIn("nothing was touched", out)

    def test_json_is_parseable_and_undo_list_covers_all(self):
        import json
        rc, out = run(GOTHAM + MARVEL, "joker", "--seed", "2", "--json")
        d = json.loads(out); self.assertEqual(d["seed"], 2); self.assertEqual(len(d["victims"]), 1)
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("\n".join(GOTHAM + MARVEL) + "\n")
        p = subprocess.run([sys.executable, str(G), "undo-list", "--json", "--targets", f.name,
                            "--now", "2026-11-19T02:45:00-05:00"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0); self.assertEqual(len(json.loads(p.stdout)["victims"]), 8)

    def test_malformed_line_refuses(self):
        self.assertEqual(run(["gotham x y"], "joker")[0], 1)


if __name__ == "__main__":
    unittest.main()
