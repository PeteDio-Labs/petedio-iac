# Authentik on AWS (PET-932). One t4g.small runs the same stack as LXC 119: server, worker,
# Postgres and Redis, plus a cloudflared connector for its own tunnel. auth.pdlab.dev moves to that
# tunnel when environments/homelab sets authentik_side = "aws", so a lab outage no longer takes the
# login page down with it. The LDAP outpost stays in the lab and connects out to auth.pdlab.dev.
#
# No inbound port. The security group has no ingress rule. The login page arrives through the
# Cloudflare tunnel, which the host dials out to, and an admin reaches the host through SSM
# Session Manager or Tailscale SSH.
#
# No secret in this root. The host reads its .env, the tunnel token and the optional Tailscale
# key from SSM Parameter Store at run time. scripts/seed-authentik-aws.sh writes them, and Pedro
# runs it (PET-511). Terraform names the parameters but never holds their values.
#
# Declared, not hand-run. Terraform writes the compose file and the host scripts to the bucket's
# config/ prefix. A timer on the host syncs that prefix every two minutes, so a version bump is a
# merged change and an aws-apply run, never an SSH session. Rollout: README.md.
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  tags = {
    project = "petedio-authentik"
    expires = var.credit_expires
  }
  account_id   = data.aws_caller_identity.current.account_id
  bucket       = "${var.name}-${local.account_id}"
  param_prefix = "/${var.name}"
  az           = "${var.aws_region}a"
}

# ── Network: one public subnet, no NAT, no inbound ─────────────────────────────────────────────
# A public address gives the host outbound reach without a NAT gateway, which would cost about
# $32 a month. The address accepts nothing, because the security group has no ingress rule.
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

# The VPC's default security group allows traffic between its members. Strip every rule, so a
# resource that lands in it by accident is closed.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default-closed" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, 0)
  availability_zone       = local.az
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "host" {
  name        = "${var.name}-host"
  description = "Authentik host: no inbound, outbound for the tunnel, images, SSM and Tailscale."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-host" }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.host.id
  description       = "Outbound only: cloudflared, image pulls, SSM, S3 and Tailscale all dial out."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ── Bucket: config the host syncs, the migration dump, nightly backups ────────────────────────
resource "aws_s3_bucket" "this" {
  bucket = local.bucket
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "backups"
    status = "Enabled"
    filter {
      prefix = "backups/"
    }
    expiration {
      days = var.backup_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  # The migration dump holds the whole database. Keep it no longer than a cutover needs.
  rule {
    id     = "migrate"
    status = "Enabled"
    filter {
      prefix = "migrate/"
    }
    expiration {
      days = 14
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  rule {
    id     = "config-history"
    status = "Enabled"
    filter {
      prefix = "config/"
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Refuse any request that is not TLS.
resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TlsOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.this]
}

# What the host syncs. Each change here reaches the host within two minutes of the apply.
locals {
  config_files = {
    "docker-compose.yml" = templatefile("${path.module}/files/docker-compose.yml.tftpl", {
      authentik_version = var.authentik_version
    })
    "settings.env" = join("\n", [
      "# Written by environments/authentik (PET-932). The host reads it on every sync.",
      "BUCKET=${local.bucket}",
      "PARAM_PREFIX=${local.param_prefix}",
      "AWS_REGION=${var.aws_region}",
      "ACCEPT_RESTORE=${var.accept_restore}",
      "",
    ])
    "authentik-sync.sh"   = file("${path.module}/files/authentik-sync.sh")
    "authentik-backup.sh" = file("${path.module}/files/authentik-backup.sh")
  }
}

resource "aws_s3_object" "config" {
  for_each = local.config_files

  bucket       = aws_s3_bucket.this.id
  key          = "config/${each.key}"
  content      = each.value
  content_type = "text/plain"
  etag         = md5(each.value)
}

# ── Host role: read its own parameters, use its own bucket, answer SSM ────────────────────────
resource "aws_iam_role" "host" {
  name                 = "${var.name}-host"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "host" {
  name = "${var.name}-host"
  role = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "OwnParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${local.param_prefix}/*"
      },
      {
        # SecureString parameters use the account's aws/ssm key. The condition limits the decrypt
        # to calls that SSM makes on the host's behalf.
        Sid       = "DecryptThroughSsm"
        Effect    = "Allow"
        Action    = "kms:Decrypt"
        Resource  = "*"
        Condition = { StringEquals = { "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com" } }
      },
      {
        Sid      = "ListOwnBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.this.arn
      },
      {
        Sid      = "ReadConfigAndMigrate"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = ["${aws_s3_bucket.this.arn}/config/*", "${aws_s3_bucket.this.arn}/migrate/*", "${aws_s3_bucket.this.arn}/backups/*"]
      },
      {
        # The host writes backups only. It cannot change its own config or the migration dump.
        Sid      = "WriteBackups"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.this.arn}/backups/*"
      },
    ]
  })
}

# Session Manager is the break-glass shell: no SSH port, no key on the host.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.name}-host"
  role = aws_iam_role.host.name
}

# ── The host ───────────────────────────────────────────────────────────────────────────────────
# Amazon Linux 2023 ships the SSM agent and the AWS CLI. The AMI id is read once: ignore_changes
# keeps a newer image from replacing a running host. dnf updates the packages instead.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_instance" "host" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.insecure_value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.host.id]
  iam_instance_profile   = aws_iam_instance_profile.host.name

  # user_data installs packages and the sync timer once. Everything after that comes from the
  # bucket, so a change here needs no new instance and does not force one.
  user_data = templatefile("${path.module}/files/user-data.sh.tftpl", {
    bucket = local.bucket
    region = var.aws_region
  })
  user_data_replace_on_change = false

  # IMDSv2 only, one hop: a container cannot reach the instance credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = false
  }

  # A stop or terminate from the console must be a decision, not a slip.
  disable_api_termination = true

  tags = { Name = var.name }

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_s3_object.config]
}
