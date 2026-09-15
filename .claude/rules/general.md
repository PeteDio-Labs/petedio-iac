# Process rules

- Read another ref with `git show <ref>:<path>` or a worktree, never `git checkout <ref> -- .` (docs/GOTCHAS.md: "`git checkout <ref> -- .` restores files you deleted, through the index (PET-408)").
- `MERGED` doesn't prove content reached `main`. Grep `origin/main` for what should be present and absent (docs/GOTCHAS.md: "`MERGED` is a fact about the pull request, not about what is on `main`").
- Defer to the source, not a copy. Name and fetch your base, and report counts with what they cover (docs/GOTCHAS.md: "A thing that holds a copy of a fact is only ever wrong in the direction nobody is looking").
- Name the branch in `git bundle create`, and check the size. About 112 bytes means no refs (docs/GOTCHAS.md: "`git bundle create - <a>..<sha>` writes a bundle with no refs").
