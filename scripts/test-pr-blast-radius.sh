#!/usr/bin/env bash
#
# test-pr-blast-radius.sh — prove the classifier fails closed, and that the
# live-apply set is really derived from the workflows rather than assumed.
#
# Two groups:
#   1. Unit tests against synthetic fixture repos built in a temp dir. These
#      stay true no matter what this repo's own workflows do.
#   2. One assertion against this repo's REAL workflows: the palworld paths
#      must classify tier-2. That is the case PET-463 exists for — merging one
#      of them runs `ansible-playbook` on the homelab runner with no operator
#      go, which is PET-442 arriving through automation.
#
# Usage: scripts/test-pr-blast-radius.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLASSIFY="$HERE/pr-blast-radius.py"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0

tier() {  # tier <repo-root> <path>...
  local root="$1"; shift
  python3 "$CLASSIFY" --repo-root "$root" --paths "$@" --json | jq -r '.tier'
}

check() {  # check <want> <label> <repo-root> <path>...
  local want="$1" label="$2" root="$3"; shift 3
  local got; got="$(tier "$root" "$@")"
  if [ "$got" = "$want" ]; then
    printf '  PASS  tier-%s  %s\n' "$got" "$label"; pass=$((pass+1))
  else
    printf '  FAIL  want tier-%s got tier-%s  %s\n' "$want" "$got" "$label"; fail=$((fail+1))
  fi
}

# --- fixtures -------------------------------------------------------------

mk_workflow() {  # mk_workflow <root> <name> <body>
  mkdir -p "$1/.github/workflows"
  printf '%s\n' "$3" > "$1/.github/workflows/$2"
}

# A repo with no workflows at all: nothing runs on merge.
PLAIN="$TMP/plain"; mkdir -p "$PLAIN"

# A repo whose push-triggered, self-hosted workflow runs a real playbook, and
# names the paths that start it. Those paths are the live-apply set.
LIVE="$TMP/live"; mkdir -p "$LIVE"
mk_workflow "$LIVE" "deploy.yml" 'name: deploy
on:
  push:
    branches: [main]
    paths:
      - ansible/roles/thing/**
      - ansible/inventory/thing.yml
jobs:
  apply:
    runs-on: [self-hosted, linux, homelab]
    steps:
      - run: ansible-playbook -i inventory/ playbooks/thing.yml'

# Same shape, but every invocation is read-only. Merging cannot change a host,
# so these paths must NOT be promoted.
READONLY="$TMP/readonly"; mkdir -p "$READONLY"
mk_workflow "$READONLY" "validate.yml" 'name: validate
on:
  push:
    branches: [main]
    paths:
      - ansible/roles/thing/**
jobs:
  check:
    runs-on: [self-hosted, linux, homelab]
    steps:
      - run: ansible-playbook -i inventory/ playbooks/thing.yml --syntax-check
      - run: ansible-playbook -i inventory/ playbooks/thing.yml --check --diff'

# A live workflow with NO paths filter fires on every merge. Naming its paths
# would mark the whole repo tier-2, so it raises the floor to tier-1 instead.
UNFILTERED="$TMP/unfiltered"; mkdir -p "$UNFILTERED"
mk_workflow "$UNFILTERED" "deploy.yml" 'name: deploy
on:
  push:
    branches: [main]
jobs:
  apply:
    runs-on: [self-hosted, linux, homelab]
    steps:
      - run: ansible-playbook -i inventory/ playbooks/thing.yml'

# The apply lives in a reusable workflow, one hop away. The caller names the
# paths; the danger is in the callee. Following `uses: ./…` is what connects
# them — this is the shape ansible-palworld.yml + ansible-stack.yml use.
INDIRECT="$TMP/indirect"; mkdir -p "$INDIRECT"
mk_workflow "$INDIRECT" "caller.yml" 'name: caller
on:
  push:
    branches: [main]
    paths:
      - ansible/roles/thing/**
jobs:
  stack:
    uses: ./.github/workflows/stack.yml'
mk_workflow "$INDIRECT" "stack.yml" 'name: stack
on:
  workflow_call: {}
jobs:
  apply:
    runs-on: [self-hosted, linux, homelab]
    steps:
      - run: ansible-playbook -i inventory/ "$PLAYBOOK"'

# --- group 1: the rules ---------------------------------------------------

echo "Tier rules"
check 0 "markdown is prose"                        "$PLAIN" docs/GOTCHAS.md
check 0 "a top-level README matches **/*.md"       "$PLAIN" README.md
check 0 "image assets"                             "$PLAIN" "a/b/slide-01.png"
check 0 "the ledger"                               "$PLAIN" PET-LOG.md
check 1 "ansible outside the live-apply set"       "$PLAIN" ansible/roles/other/tasks/main.yml
check 1 "scripts do not run themselves on merge"   "$PLAIN" scripts/seed.sh
check 2 "a workflow edit moves the trust boundary" "$PLAIN" .github/workflows/ci.yml
check 2 "a composite action is the same boundary"  "$PLAIN" .github/actions/x/action.yml
check 2 "Vault roles and policies"                 "$PLAIN" vault-config/auth.tf
check 2 "Terraform inputs"                         "$PLAIN" environments/homelab/terraform.tfvars
check 2 "provider pinning"                         "$PLAIN" environments/homelab/.terraform.lock.hcl

echo
echo "Failing closed"
check 2 "an unrecognised path is tier-2"           "$PLAIN" some/new/thing.rb
check 2 "a bare unknown extension is tier-2"       "$PLAIN" thing.bin

echo
echo "Highest tier wins"
check 2 "one workflow edit promotes a docs PR"     "$PLAIN" docs/a.md README.md .github/workflows/ci.yml
check 1 "one ansible file promotes a docs PR"      "$PLAIN" docs/a.md ansible/roles/other/tasks/main.yml

echo
echo "The live-apply set, derived from the workflows"
check 2 "a path that starts a real playbook"       "$LIVE" ansible/roles/thing/tasks/main.yml
check 2 "an exact-match trigger path"              "$LIVE" ansible/inventory/thing.yml
check 1 "a sibling path that starts nothing"       "$LIVE" ansible/roles/other/tasks/main.yml
check 1 "read-only ansible does not promote"       "$READONLY" ansible/roles/thing/tasks/main.yml
check 2 "an apply reached through a reusable call" "$INDIRECT" ansible/roles/thing/tasks/main.yml
check 1 "an unfiltered live workflow raises the floor" "$UNFILTERED" docs/a.md

# --- group 2: the comment-only Terraform test, over a real git diff --------

echo
echo "Terraform, over a real git history"
G="$TMP/git"; mkdir -p "$G"
git -C "$G" init -q -b main
git -C "$G" config user.email t@t; git -C "$G" config user.name t
mkdir -p "$G/environments/x"
cat > "$G/environments/x/main.tf" <<'TF'
# a comment
resource "null_resource" "a" {
  triggers = { v = "1" }
}
TF
git -C "$G" add -A; git -C "$G" commit -qm base
BASE="$(git -C "$G" rev-parse HEAD)"

git -C "$G" checkout -qb comments
cat > "$G/environments/x/main.tf" <<'TF'
# a comment, reworded after the rack loss
resource "null_resource" "a" {
  triggers = { v = "1" }
}
TF
git -C "$G" commit -qam "comments only"
got="$(python3 "$CLASSIFY" --repo-root "$G" --base "$BASE" --json | jq -r '.tier')"
if [ "$got" = "1" ]; then
  printf '  PASS  tier-1  comment-only .tf cannot move the plan\n'; pass=$((pass+1))
else
  printf '  FAIL  want tier-1 got tier-%s  comment-only .tf\n' "$got"; fail=$((fail+1))
fi

git -C "$G" checkout -q main; git -C "$G" checkout -qb real
sed -i.bak 's/v = "1"/v = "2"/' "$G/environments/x/main.tf"; rm -f "$G/environments/x/main.tf.bak"
git -C "$G" commit -qam "a real change"
got="$(python3 "$CLASSIFY" --repo-root "$G" --base "$BASE" --json | jq -r '.tier')"
if [ "$got" = "2" ]; then
  printf '  PASS  tier-2  a .tf change that moves the plan\n'; pass=$((pass+1))
else
  printf '  FAIL  want tier-2 got tier-%s  real .tf change\n' "$got"; fail=$((fail+1))
fi

# --- group 3: this repo, for real -----------------------------------------
#
# Not a fixture. If ansible-palworld.yml still triggers on push for its role
# paths, a change to one of them MUST read tier-2. Should that workflow ever be
# removed on purpose, this skips rather than fails — but it will not go quiet
# while the workflow is still there.

echo
echo "This repo's real workflows"
PALWORLD_WF="$REPO_ROOT/.github/workflows/ansible-palworld.yml"
if [ ! -f "$PALWORLD_WF" ]; then
  echo "  SKIP  ansible-palworld.yml is gone — re-derive the live-apply set by hand once"
else
  check 2 "ansible/roles/palworld/** runs a live playbook on merge" \
        "$REPO_ROOT" ansible/roles/palworld/tasks/main.yml
  check 2 "the palworld inventory host_vars file too" \
        "$REPO_ROOT" ansible/inventory/host_vars/palworld-234.yml
  check 1 "an unrelated role in the same tree stays tier-1" \
        "$REPO_ROOT" ansible/roles/claude-code/defaults/main.yml
fi

echo
echo "-----"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
