variable "region" {
  description = "Keep equal to bootstrap/ var.infra_region. The state backend stays in us-east-1 regardless (see versions.tf)."
  type        = string
  default     = "sa-east-1"
}

variable "project" {
  description = "Name prefix. Must match the prefix the deploy role is scoped to in bootstrap/."
  type        = string
  default     = "devbox"
}

variable "instance_type" {
  type    = string
  default = "t3.large"
}

variable "root_volume_gb" {
  type    = number
  default = 50
}

variable "tailnet_dns_name" {
  description = "Your tailnet's MagicDNS suffix, e.g. tail1234.ts.net (not a secret). Used to print the access URL."
  type        = string
}

variable "tailscale_hostname" {
  description = "Machine name on the tailnet. The URL is https://<this>.<tailnet_dns_name>"
  type        = string
  default     = "devbox"
}

variable "code_server_password_param" {
  description = "Name of the SSM SecureString holding the code-server password (created by hand)."
  type        = string
  default     = "/devbox/code-server-password"
}

variable "tailscale_authkey_param" {
  description = "Name of the SSM SecureString holding the ephemeral, tagged Tailscale auth key (created by hand)."
  type        = string
  default     = "/devbox/tailscale-authkey"
}
