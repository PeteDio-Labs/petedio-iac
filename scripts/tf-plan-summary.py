#!/usr/bin/env python3
"""Turn `terraform show -json <plan>` into a public-safe pull request comment (PET-866).

Prints counts and resource addresses only, never attribute values, because the comment is public.
It states how many resources the prior state held, so a plan that read nothing cannot pass for a
clean plan. Exit 0 with a summary, 1 when it read nothing (empty state or malformed plan).

Usage: tf-plan-summary.py plan.json
"""
import json
import sys


def redact(address):
    """Drop for_each and count keys: an evaluated key can carry a secret into a public comment.

    A key is a quoted string with escapes, so a `]` inside quotes does not end it.
    """
    out, i, n = [], 0, len(address)
    while i < n:
        if address[i] != "[":
            out.append(address[i])
            i += 1
            continue
        out.append("[…]")
        i += 1
        in_quote = False
        while i < n:
            c = address[i]
            if in_quote and c == "\\":
                i += 2
                continue
            if c == '"':
                in_quote = not in_quote
            elif c == "]" and not in_quote:
                i += 1
                break
            i += 1
    return "".join(out)


def main():
    plan = json.load(open(sys.argv[1]))
    changes = plan.get("resource_changes", [])

    def count(mod):
        n = len(mod.get("resources", []))
        for c in mod.get("child_modules", []):
            n += count(c)
        return n

    prior = count(plan.get("prior_state", {}).get("values", {}).get("root_module", {}))
    buckets = {"create": [], "update": [], "replace": [], "destroy": [],
               "import": [], "move": [], "other": []}
    for r in changes:
        ch = r.get("change", {})
        a = ch.get("actions", [])
        if ch.get("importing"):
            buckets["import"].append(redact(r["address"]))
        if r.get("previous_address") and r["previous_address"] != r["address"]:
            buckets["move"].append(redact(r["address"]))
        if a == ["no-op"] or a == ["read"]:
            continue
        if "delete" in a and "create" in a:
            buckets["replace"].append(redact(r["address"]))
        elif "delete" in a:
            buckets["destroy"].append(redact(r["address"]))
        elif "create" in a:
            buckets["create"].append(redact(r["address"]))
        elif "update" in a:
            buckets["update"].append(redact(r["address"]))
        else:
            # forget, or an action this script does not know: list it, never call it "no changes".
            buckets["other"].append(redact(r["address"]) + " (" + ",".join(a) + ")")
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
    for kind in ("create", "update", "import", "move", "other"):
        if buckets[kind]:
            out.append(f"\n{kind}:")
            shown = sorted(buckets[kind])[:100]
            out += [f"- `{a}`" for a in shown]
            if len(buckets[kind]) > len(shown):
                out.append(f"- …and {len(buckets[kind]) - len(shown)} more")
    if prior == 0 or not changes:
        out.append("\n**The plan examined nothing, so this is not a clean plan.** The state read as empty or the plan held no resources.")
    elif not any(buckets.values()):
        out.append("\nNo changes. The configuration matches the state.")
    elif buckets["import"] or buckets["move"] or buckets["other"]:
        out.append(f"\n{len(buckets['import'])} import(s), {len(buckets['move'])} move(s), "
                   f"{len(buckets['other'])} other action(s) are listed above.")
    print("\n".join(out))
    if prior == 0 or not changes:
        print("\nERROR: plan examined 0 resources", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
