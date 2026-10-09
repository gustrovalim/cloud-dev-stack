output "state_bucket" {
  description = "Set as the GitHub repo variable TF_STATE_BUCKET."
  value       = aws_s3_bucket.state.id
}

output "deploy_role_arn" {
  description = "Set as the GitHub repo variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.deploy.arn
}

output "plan_role_arn" {
  description = "Set as the GitHub repo variable AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.plan.arn
}
