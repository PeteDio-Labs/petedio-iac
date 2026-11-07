# API spend cap

Nothing in this repo calls the Anthropic API. `lab-agent` runs on local Qwen through Ollama,
the Anthropic gateway is retired (`PET-744`), and the merge desk's fallback reviewer is also
local Qwen (`PET-751`). Pedro chose "Qwen only" on 2026-11-07 (`PET-747`), so the cap is $0.

## Before any key exists

To add a paid model lane later, set the cap first:

1. In the Anthropic Console, create a workspace for the lane. Set its monthly spend limit to
   $25 and its notification threshold to 80%.
2. Create the lane's key inside that workspace only. A key from the default workspace has no
   cap.
3. Place the key with a script that Pedro runs. No session places a credential.
4. Add a budget guard in `pete-bot` in the same PR as the lane. The guard records tokens times
   price per call, refuses at 100%, and falls back to Qwen.

The Console limit is the hard cap. A guard in code is a second check and cannot replace it.

## Check that no lane exists

To confirm nothing calls the API, run this from the repo root of `pete-bot`:

```bash
grep -rIn "api.anthropic.com\|ANTHROPIC_API_KEY" src/; rc=$?
case $rc in
  0) echo "a lane exists: set the cap" ;;
  1) echo "no lane: grep read src/ and found no match" ;;
  *) echo "grep failed (status $rc): nothing was examined" >&2; exit "$rc" ;;
esac
```

The command reads `src/` only. A caller outside it, such as a script, is not covered.
