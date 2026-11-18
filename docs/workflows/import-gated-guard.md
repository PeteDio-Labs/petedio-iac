# import-gated-guard

Source: `.github/workflows/import-gated-guard.yml`

| | |
|---|---|
| **Trigger** | `pull_request` (labeled, unlabeled). |
| **Runner** | GitHub-hosted (`ubuntu-latest`) |
| **Touches** | Nothing. Fails while a PR carries the `import-gated` label. |
| **Vault** | None. |
| **Secrets** | None. |
| **Gates** | A process gate: a human `terraform import` must happen before merge, or apply-on-merge tries to create a live resource (PET-123). Remove the label after the import. |
| **Run it** | Add or remove the label. |


