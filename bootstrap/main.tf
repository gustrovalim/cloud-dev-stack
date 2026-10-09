data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  bucket     = "${var.project}-tfstate-${local.account_id}"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Stack     = "bootstrap"
    Repo      = "cloud-dev-stack"
  }
}

# ---------------------------------------------------------------------------
# State bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = local.bucket

  # State must outlive the disposable stack. Remove this by hand if you ever retire the project.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    # SSE-S3 (AES256): no KMS key to manage and no extra KMS grants for the roles.
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Refuse any non-TLS request.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# Old state versions are only for emergencies; don't keep them forever.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
  depends_on = [aws_s3_bucket_versioning.state]
}

# ---------------------------------------------------------------------------
# GitHub OIDC
# ---------------------------------------------------------------------------
# No thumbprint_list: AWS validates GitHub's certificate chain itself, so the argument is optional.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Deploy role: apply/destroy. Only tokens minted for the main branch of this repo can assume it.
# Security tradeoff: scheduled and workflow_dispatch runs on main both carry this exact sub,
# so anyone who can push to main (or change workflows on main) can use this role. Protect main.
resource "aws_iam_role" "deploy" {
  name = "${var.project}-github-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "${var.github_sub_prefix}:ref:refs/heads/${var.deploy_branch}"
        }
      }
    }]
  })
}

# Plan role: read-only, assumable from pull requests of this repo (never from forks: GitHub
# does not issue OIDC tokens to fork PRs). It cannot create, change or delete anything.
resource "aws_iam_role" "plan" {
  name = "${var.project}-github-plan"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "${var.github_sub_prefix}:pull_request"
        }
      }
    }]
  })
}

locals {
  state_object_arn = "${aws_s3_bucket.state.arn}/infra/*"
  iam_arn_prefix   = "arn:aws:iam::${local.account_id}"
  instance_role    = "${local.iam_arn_prefix}:role/${var.project}-*"
  instance_profile = "${local.iam_arn_prefix}:instance-profile/${var.project}-*"
}

resource "aws_iam_role_policy" "deploy" {
  name = "deploy-infra"
  role = aws_iam_role.deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StateList"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.state.arn
        Condition = {
          StringLike = { "s3:prefix" = ["infra/*"] }
        }
      },
      {
        # Includes the .tflock object used by use_lockfile.
        Sid      = "StateObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = local.state_object_arn
      },
      {
        # BROAD GRANT: EC2/VPC create and delete actions mostly cannot be limited to resource ARNs
        # (the resources do not exist yet). Limited to one region instead.
        Sid      = "Ec2AndVpcInRegion"
        Effect   = "Allow"
        Action   = "ec2:*"
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.region }
        }
      },
      {
        Sid    = "InstanceRoleAndProfile"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateAssumeRolePolicy",
          "iam:TagRole", "iam:UntagRole",
          "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
          "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
        ]
        Resource = [local.instance_role, local.instance_profile]
      },
      {
        # Only the SSM core policy may be attached, and only to ${var.project}-* roles.
        Sid      = "AttachSsmPolicyOnly"
        Effect   = "Allow"
        Action   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
        Resource = local.instance_role
        Condition = {
          ArnEquals = { "iam:PolicyARN" = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" }
        }
      },
      {
        Sid      = "PassInstanceRoleToEc2"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = local.instance_role
        Condition = {
          StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
        }
      },
      {
        # Public AMI parameter only. The secret parameters are never readable by this role.
        Sid      = "ResolveAmi"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.region}::parameter/aws/service/ami-amazon-linux-latest/*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "plan" {
  name = "plan-infra"
  role = aws_iam_role.plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StateList"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.state.arn
        Condition = {
          StringLike = { "s3:prefix" = ["infra/*"] }
        }
      },
      {
        # Read the state only. Plans run with -lock=false, so no write is needed.
        Sid      = "StateRead"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.state.arn}/infra/terraform.tfstate"
      },
      {
        Sid      = "Ec2Describe"
        Effect   = "Allow"
        Action   = "ec2:Describe*"
        Resource = "*"
      },
      {
        Sid    = "IamRead"
        Effect = "Allow"
        Action = [
          "iam:GetRole", "iam:GetRolePolicy", "iam:GetInstanceProfile",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
        ]
        Resource = [local.instance_role, local.instance_profile]
      },
      {
        Sid      = "ResolveAmi"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.region}::parameter/aws/service/ami-amazon-linux-latest/*"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Cost guardrail
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}
