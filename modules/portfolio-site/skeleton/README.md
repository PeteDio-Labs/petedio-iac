# portfolio (skeleton)

Copy this directory into the `PeteDio-Labs/portfolio` repo. Static HTML and one CSS file built
with the Tailwind CLI under Bun. No React and no runtime JavaScript framework.

```bash
bun install
bun run build   # writes dist/
bun run dev     # rebuilds CSS on change
```

The brand tokens and components come from the toonish-ui kit (PET-809). Until it lands,
`src/input.css` holds placeholder tokens in an `@theme` block: replace them there.

## Deploy

`.github/workflows/deploy.yml` runs on a push to `main`. It assumes the AWS role over OIDC,
syncs `dist/` to the bucket and invalidates the cache. Set these repository variables from the
`portfolio-site` module outputs: `AWS_ROLE_ARN`, `BUCKET`, `DISTRIBUTION_ID`.
