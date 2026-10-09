variable "region" {
  description = "Region for the state bucket, OIDC provider and budget (kept stable: the state lives here)."
  type        = string
  default     = "us-east-1"
}

variable "infra_region" {
  description = "Region where infra/ runs. The deploy role's EC2 grant and the AMI parameter ARNs are scoped to it. Keep equal to infra/ var.region."
  type        = string
  default     = "sa-east-1"
}

variable "project" {
  description = "Name prefix for every resource. The deploy role's IAM permissions are scoped to this prefix."
  type        = string
  default     = "devbox"
}

variable "github_sub_prefix" {
  description = <<-EOT
    Prefix of the GitHub OIDC "sub" claim for this repo. Repos created after 2026-07-15 use the
    immutable format with numeric IDs: repo:<owner>@<owner-id>/<repo>@<repo-id>
    Check yours with: gh api repos/<owner>/<repo>/actions/oidc/customization/sub
  EOT
  type        = string
  default     = "repo:gustrovalim@53983036/cloud-dev-stack@1411121301"
}

variable "deploy_branch" {
  type    = string
  default = "main"
}

variable "budget_email" {
  description = "Email that receives AWS Budgets alerts."
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly cost budget in USD."
  type        = number
  default     = 30
}
