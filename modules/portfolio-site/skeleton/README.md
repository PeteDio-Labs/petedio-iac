# portfolio (skeleton)

Copy this directory into the `PeteDio-Labs/pdlabs-portfolio` repo. Static HTML and one CSS file built
with the Tailwind CLI under Bun. No React and no runtime JavaScript framework.

```bash
bun install
bun run build   # writes dist/
bun run dev     # rebuilds CSS on change
```

The brand tokens and components come from the toonish-ui kit (PET-809). Until it lands,
`src/input.css` holds placeholder tokens in an `@theme` block: replace them there.

## Deploy

`.github/workflows/deploy.yml` runs on a push to `main` and matches `deploy_auth = "user"`. It signs in
with the deploy user's key from the `production` environment secrets
(`bash scripts/portfolio-deploy-key.sh` in `petedio-iac` creates them), syncs `dist/` to the bucket and
invalidates the cache. Set the repository variables `BUCKET` and `DISTRIBUTION_ID` from the module
outputs.

For `deploy_auth = "oidc"`, replace the key secrets with `permissions: id-token: write`, an
`aws-actions/configure-aws-credentials` step with `role-to-assume` set to the `deploy_role_arn` output,
and drop the environment.
