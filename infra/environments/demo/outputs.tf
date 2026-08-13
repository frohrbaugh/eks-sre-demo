# These print real identifiers. Redact them in anything committed to
# docs/evidence/ - see docs/plan.md section 24.3.

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "region" {
  value = var.aws_region
}

output "ecr_repository_url" {
  description = "Pass to the Makefile as ECR_REPOSITORY."
  value       = aws_ecr_repository.api.repository_url
}

output "demo_bucket_name" {
  value = aws_s3_bucket.demo.id
}

output "github_role_arn" {
  description = "Set as the role-to-assume in .github/workflows/ci.yaml."
  value       = aws_iam_role.github_actions.arn
}

output "api_pod_role_arn" {
  value = aws_iam_role.api_pod.arn
}

output "vpc_id" {
  description = "Needed by the AWS Load Balancer Controller install."
  value       = module.vpc.vpc_id
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "make_variables" {
  description = "Copy-paste into the Makefile invocation or your shell."
  value = join(" ", [
    "AWS_REGION=${var.aws_region}",
    "ECR_REPOSITORY=${aws_ecr_repository.api.repository_url}",
    "DEMO_BUCKET=${aws_s3_bucket.demo.id}",
  ])
}
