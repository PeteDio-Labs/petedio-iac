# offsite-watchdog (PET-722)

An AWS Lambda that watches the lab from outside it. The lab sends a heartbeat to the function
URL every 2 minutes. A scheduled run of the same function posts to Discord when the heartbeat
stops (house power, internet, pve03 or 247 down) and probes the public endpoints in
`var.public_checks`. It costs $0 to $1 a month: one Lambda, one on-demand DynamoDB table, one
EventBridge rule, two SSM parameters.

## Account limits

The account is "Dream It Ship It" (us-east-2) on the AWS Free plan. As of 2026-10-21 it holds $100
of credit that expires on **2027-04-20**, and access ends when the credit or the time runs out
unless the plan is upgraded. This module spends cents a month, so the date is the limit. Before
2027-04-06, upgrade the account to a paid plan or move the module (PET-723 tracks it). When the
plan ends, the watchdog stops without warning: the lab's heartbeat gets no answer, and the
`lab-watchdog` unit shows the failed beat on 247.

Nothing here runs from CI. Apply it by hand from claude-247, on Pedro's word.

## Before the first apply

1. Create a $5 monthly AWS Budget with email alerts. Do it before any resource exists.
2. Create the boundary policy and the IAM user `petedio-terraform-watchdog` with its inline policy (next section), and an access key.
3. Run `scripts/seed-aws-watchdog-vault.sh`. It stores the keys, a Discord webhook and a
   generated heartbeat secret in `kv/services/aws-watchdog`.

## Apply

```bash
cd environments/offsite-watchdog
# Any token that reads kv/services/aws-watchdog works. The ansible AppRole does.
export VAULT_ADDR=https://192.168.50.223:8200 VAULT_CACERT=../homelab/vault-ca.crt
export AWS_ACCESS_KEY_ID=<MinIO state key> AWS_SECRET_ACCESS_KEY=<MinIO state secret>
terraform init && terraform plan -var permissions_boundary_arn=<ARN of petedio-watchdog-boundary>
```

The two `AWS_*` variables are the MinIO state backend's keys. The AWS provider ignores them and
authenticates from Vault, so the two never collide. Read the plan before the apply: expect 13
resources to add (two SSM parameters, the table, a log group, a role and its policy, the function,
its URL and two URL permissions, an EventBridge rule, its target and permission).

After the apply, run `scripts/seed-aws-watchdog-vault.sh --heartbeat-url` with the
`heartbeat_url` output, then `scripts/deploy-lab-watchdog.sh` to land the heartbeat on 247.

## IAM: the boundary policy and the apply user

The apply user creates an IAM role, so it could create a role more powerful than itself and run
code as that role through the Lambda. A permissions boundary closes that: the user may create the
function role only with the boundary below attached, and no policy attached to the role can grant
more than the boundary allows. Pedro creates the boundary, so the apply user cannot edit it.

**1. Create the boundary policy** `petedio-watchdog-boundary` (IAM, Policies, Create policy, JSON),
as a different identity than the apply user:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["dynamodb:GetItem", "dynamodb:PutItem"],
     "Resource": "arn:aws:dynamodb:*:*:table/petedio-watchdog-state"},
    {"Effect": "Allow", "Action": "ssm:GetParameter",
     "Resource": "arn:aws:ssm:*:*:parameter/petedio-watchdog/*"},
    {"Effect": "Allow", "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
     "Resource": "arn:aws:logs:*:*:log-group:/aws/lambda/petedio-watchdog:*"}
  ]
}
```

Copy its ARN into `terraform.tfvars` as `permissions_boundary_arn`. Replace `ACCOUNT_ID` below with
the account's 12 digits.

**2. Attach this inline policy to `petedio-terraform-watchdog`.** It is scoped by name, and every
role action requires the boundary:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "lambda:*",
     "Resource": "arn:aws:lambda:*:*:function:petedio-watchdog"},
    {"Effect": "Allow", "Action": "events:*",
     "Resource": "arn:aws:events:*:*:rule/petedio-watchdog-*"},
    {"Effect": "Allow", "Action": "dynamodb:*",
     "Resource": "arn:aws:dynamodb:*:*:table/petedio-watchdog-*"},
    {"Effect": "Allow", "Action": "logs:*",
     "Resource": "arn:aws:logs:*:*:log-group:/aws/lambda/petedio-watchdog*"},
    {"Effect": "Allow", "Action": "ssm:*",
     "Resource": "arn:aws:ssm:*:*:parameter/petedio-watchdog/*"},
    {"Effect": "Allow", "Action": ["iam:CreateRole", "iam:PutRolePolicy"],
     "Resource": "arn:aws:iam::ACCOUNT_ID:role/petedio-watchdog-*",
     "Condition": {"StringEquals": {
       "iam:PermissionsBoundary": "arn:aws:iam::ACCOUNT_ID:policy/petedio-watchdog-boundary"}}},
    {"Effect": "Allow",
     "Action": ["iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:DeleteRolePolicy",
                "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
                "iam:ListInstanceProfilesForRole"],
     "Resource": "arn:aws:iam::ACCOUNT_ID:role/petedio-watchdog-*"},
    {"Effect": "Allow", "Action": "iam:PassRole",
     "Resource": "arn:aws:iam::ACCOUNT_ID:role/petedio-watchdog-*",
     "Condition": {"StringEquals": {"iam:PassedToService": "lambda.amazonaws.com"}}},
    {"Effect": "Allow", "Action": "iam:GetPolicy",
     "Resource": "arn:aws:iam::ACCOUNT_ID:policy/petedio-watchdog-boundary"},
    {"Effect": "Allow",
     "Action": ["logs:DescribeLogGroups", "ssm:DescribeParameters", "dynamodb:ListTables",
                "lambda:ListFunctions", "events:ListRules", "sts:GetCallerIdentity"],
     "Resource": "*"}
  ]
}
```

`iam:PutRolePolicy` carries the boundary condition on purpose: AWS evaluates the boundary on the
role, so an inline policy that grants more has no effect beyond the boundary. The user holds no
`iam:AttachRolePolicy`, `iam:DeleteRolePermissionsBoundary` or `iam:PutRolePermissionsBoundary`.

If the plan needs an action the policy lacks, the apply names it. Add that one action and record it
here, and never add `iam:*` or drop the boundary condition.

## Rotation

- Discord webhook: re-run the seed script, then bump `value_wo_version` in `main.tf` and apply.
- Heartbeat secret: delete the field in Vault, re-run the seed script, bump `value_wo_version` on
  `heartbeat_secret`, apply, then run `scripts/deploy-lab-watchdog.sh`.

## Tests

`python3 scripts/test-offsite-watchdog.py` drives `lambda/handler.py` against fakes. It is not wired
into CI. `terraform validate` needs the provider downloads, so run it from 247 before the first plan.
