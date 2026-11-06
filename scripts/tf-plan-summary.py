#!/usr/bin/env python3
"""Turn `terraform show -json <plan>` into a public-safe pull request comment (PET-866).

Prints counts and resource addresses only, never attribute values, because the comment is public.
It states how many resources the prior state held, so a plan that read nothing cannot pass for a
clean plan. Exit 0 with a summary, 1 when it read nothing (empty state or malformed plan).

Usage: tf-plan-summary.py plan.json
"""
import json
import sys


def main():
    plan = json.load(open(sys.argv[1]))
    changes = plan.get("resource_changes", [])

    def count(mod):
        n = len(mod.get("resources", []))
        for c in mod.get("child_modules", []):
            n += count(c)
        return n

    prior = count(plan.get("prior_state", {}).get("values", {}).get("root_module", {}))
    buckets = {"create": [], "update": [], "replace": [], "destroy": []}
    for r in changes:
        a = r.get("change", {}).get("actions", [])
        if a == ["no-op"] or a == ["read"]:
            continue
        if "delete" in a and "create" in a:
            buckets["replace"].append(r["address"])
        elif "delete" in a:
            buckets["destroy"].append(r["address"])
        elif "create" in a:
            buckets["create"].append(r["address"])
        elif "update" in a:
            buckets["update"].append(r["address"])
    out = []
    removes = buckets["replace"] + buckets["destroy"]
    if removes:
        out.append(f"### ⚠ This plan removes {len(removes)} resource(s)")
        out.append("The merge would stop at `plan-gate` unless `ALLOW_DESTROY=true`.\n")
        for kind in ("destroy", "replace"):
            for a in sorted(buckets[kind]):
                out.append(f"- **{kind}** `{a}`")
        out.append("")
    out.append(
        f"**{len(buckets['create'])} to add, {len(buckets['update'])} to change, "
        f"{len(buckets['replace'])} to replace, {len(buckets['destroy'])} to destroy.** "
        f"Examined {len(changes)} planned resources against a state of {prior} resources.")
    for kind in ("create", "update"):
        if buckets[kind]:
            out.append(f"\n{kind}:")
            out += [f"- `{a}`" for a in sorted(buckets[kind])]
    if not any(buckets.values()):
        out.append("\nNo changes. The configuration matches the state.")
    print("\n".join(out))
    if prior == 0 or not changes:
        print("\nERROR: plan examined 0 resources", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
