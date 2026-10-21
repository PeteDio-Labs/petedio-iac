# offsite-watchdog (PET-722)

An AWS Lambda that watches the lab from outside it. The lab sends a heartbeat to the function
URL every 2 minutes. A scheduled run of the same function posts to Discord when the heartbeat
stops (house power, internet, pve03 or 247 down) and probes the public endpoints in
`var.public_checks`. It costs $0 to $1 a month: one Lambda, one on-demand DynamoDB table, one
EventBridge rule, two SSM parameters.

Nothing here runs from CI. Apply it by hand from claude-247, on Pedro's word.

## Before the first apply

1. Create a $5 monthly AWS Budget with email alerts. Do it before any resource exists.
2. Create the IAM user `petedio-terraform-watchdog` with the policy below and an access key.
3. Run `scripts/seed-aws-watchdog-vault.sh`. It stores the keys, a Discord webhook and a
   generated heartbeat secret in `kv/services/aws-watchdog`.

## Apply

```bash
cd environments/offsite-watchdog
# Any token that reads kv/services/aws-watchdog works. The ansible AppRole does.
export VAULT_ADDR=https://192.168.50.223:8200 VAULT_CACERT=../homelab/vault-ca.crt
export AWS_ACCESS_KEY_ID=<MinIO state key> AWS_SECRET_ACCESS_KEY=<MinIO state secret>
terraform init && terraform plan
```

The two `AWS_*` variables are the MinIO state backend's keys. The AWS provider ignores them and
authenticates from Vault, so the two never collide. Read the plan before the apply: expect 13
resources to add (two SSM parameters, the table, a log group, a role and its policy, the function,
its URL and two URL permissions, an EventBridge rule, its target and permission).

After the apply, run `scripts/seed-aws-watchdog-vault.sh --heartbeat-url` with the
`heartbeat_url` output, then `scripts/deploy-lab-watchdog.sh` to land the heartbeat on 247.

## IAM policy for `petedio-terraform-watchdog`

Scoped by resource name. It cannot touch anything not named `petedio-watchdog*`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "lambda:*",
     "Resource": "arn:aws:lambda:*:*:function:petedio-watchdog*"},
    {"Effect": "Allow", "Action": "events:*",
     "Resource": "arn:aws:events:*:*:rule/petedio-watchdog-*"},
    {"Effect": "Allow", "Action": "dynamodb:*",
     "Resource": "arn:aws:dynamodb:*:*:table/petedio-watchdog-*"},
    {"Effect": "Allow", "Action": "logs:*",
     "Resource": "arn:aws:logs:*:*:log-group:/aws/lambda/petedio-watchdog*"},
    {"Effect": "Allow", "Action": "ssm:*",
     "Resource": "arn:aws:ssm:*:*:parameter/petedio-watchdog/*"},
    {"Effect": "Allow",
     "Action": ["iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:PassRole", "iam:TagRole",
                "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
                "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole"],
     "Resource": "arn:aws:iam::*:role/petedio-watchdog-*"},
    {"Effect": "Allow",
     "Action": ["logs:DescribeLogGroups", "ssm:DescribeParameters", "dynamodb:ListTables",
                "lambda:ListFunctions", "events:ListRules", "sts:GetCallerIdentity"],
     "Resource": "*"}
  ]
}
```

If the plan needs an action the policy lacks, the apply says which. Add that one action and
record it here.

## Rotation

- Discord webhook: re-run the seed script, then bump `value_wo_version` in `main.tf` and apply.
- Heartbeat secret: delete the field in Vault, re-run the seed script, bump `value_wo_version` on
  `heartbeat_secret`, apply, then run `scripts/deploy-lab-watchdog.sh`.

## Tests

`python3 scripts/test-offsite-watchdog.py` drives `lambda/handler.py` against fakes. It is not wired
into CI. `terraform validate` needs the provider downloads, so run it from 247 before the first plan.
