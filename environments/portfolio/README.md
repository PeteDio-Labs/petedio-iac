# portfolio

Root for `modules/portfolio-site` (PET-816). It has its own state key, `portfolio/terraform.tfstate`,
and nothing in CI applies it. Run it by hand, in the order in `modules/portfolio-site/README.md`.

```bash
cd environments/portfolio
terraform init
terraform plan -var aws_profile=<profile for account 847547470418>
```

`terraform validate` is not in CI for this root. Run it and read the plan before the first apply.

The deploy role trusts only `PeteDio-Labs/pdlabs-portfolio` on `main`. After the apply, set
`AWS_ROLE_ARN`, `BUCKET` and `DISTRIBUTION_ID` as repository variables from the outputs.
