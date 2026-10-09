data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# Latest Amazon Linux 2023 (x86_64), resolved at plan time from the public SSM parameter.
data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Stack     = "infra"
    Repo      = "cloud-dev-stack"
  }
}

# ---------------------------------------------------------------------------
# Network: one public subnet, no NAT gateway (the instance's public IP is only for outbound).
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.0.0/26"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Tradeoff: the instance has a public IP, but this group has NO inbound rules, so nothing can
# reach it from the internet. Access is via Tailscale (outbound-initiated) and SSM Session Manager.
resource "aws_security_group" "instance" {
  name        = "${var.project}-instance"
  description = "No inbound. Outbound only."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-instance" }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.instance.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Outbound for package installs, GitHub, Tailscale and SSM"
}

# ---------------------------------------------------------------------------
# Instance role: SSM Session Manager + read the two secrets it needs at boot.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "instance" {
  name = "${var.project}-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_secrets" {
  name = "read-boot-secrets"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "ssm:GetParameter"
      Resource = [
        "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.code_server_password_param}",
        "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.tailscale_authkey_param}",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.project}-instance"
  role = aws_iam_role.instance.name
}

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------
resource "aws_instance" "dev" {
  ami                    = nonsensitive(data.aws_ssm_parameter.ami.value)
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  metadata_options {
    http_tokens = "required" # IMDSv2 only
    # Hop limit 1 keeps containers (one extra network hop) from reading the instance role's
    # credentials. Raise to 2 if you need AWS access from inside Docker containers.
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  # Config is passed as exported variables ahead of the script. None of it is secret: the
  # script fetches the password and auth key from SSM itself.
  user_data = join("\n", [
    "#!/bin/bash",
    "export AWS_REGION='${var.region}'",
    "export CODE_SERVER_PASSWORD_PARAM='${var.code_server_password_param}'",
    "export TAILSCALE_AUTHKEY_PARAM='${var.tailscale_authkey_param}'",
    "export TAILSCALE_HOSTNAME='${var.tailscale_hostname}'",
    "export EXTENSIONS_B64='${base64encode(file("${path.module}/../scripts/extensions.txt"))}'",
    file("${path.module}/../scripts/user-data.sh"),
  ])
  user_data_replace_on_change = true

  tags = { Name = "${var.project}-dev" }

  depends_on = [aws_route_table_association.public, aws_iam_role_policy.read_secrets]
}
