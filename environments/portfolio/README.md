# portfolio

Root for `modules/portfolio-site` (PET-816). It has its own state key, `portfolio/terraform.tfstate`,
and nothing in CI applies it. Run it by hand, in the order in `modules/portfolio-site/README.md`.

```bash
cd environments/portfolio
terraform init
terraform plan -var aws_profile=<profile for account 847547470418>
```

`terraform validate` is not in CI for this root. Run it and read the plan before the first apply.

The account's SCP denies the GitHub OIDC provider, so the deploy identity is an IAM user
(`deploy_auth = "user"`). After the apply, run `bash scripts/portfolio-deploy-key.sh --profile <profile>`
to create its key and store it as secrets on the `production` environment of
`PeteDio-Labs/pdlabs-portfolio`, then set `BUCKET` and `DISTRIBUTION_ID` as repository variables from
the outputs.
