output "access_url" {
  description = "Open this on a device that is signed in to your tailnet. Ready a few minutes after apply."
  value       = "https://${var.tailscale_hostname}.${var.tailnet_dns_name}"
}

output "instance_id" {
  value = aws_instance.dev.id
}

output "ssm_session_command" {
  description = "Second terminal path, and where to read the boot log: /var/log/devbox-init.log"
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.dev.id}"
}
