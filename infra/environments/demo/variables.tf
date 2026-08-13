variable "aws_region" {
  type        = string
  description = "Region for all resources."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. Kept neutral - no employer branding."
  default     = "sre-demo"
}

variable "kubernetes_version" {
  type        = string
  description = <<-EOT
    A currently supported EKS Kubernetes version, verified in the target region:
      aws eks describe-cluster-versions --region <region>
    Pin it. Never let this drift implicitly.
  EOT
}

variable "public_access_cidrs" {
  type        = list(string)
  description = <<-EOT
    CIDRs allowed to reach the public EKS API endpoint.

    This is the operator's home IP address. It is NEVER committed - the real
    value lives in a gitignored terraform.tfvars. Leaving it as 0.0.0.0/0 is
    rejected by the validation below.
  EOT

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Refusing to expose the EKS API endpoint to the entire internet. Set your own /32."
  }
}

variable "github_repository" {
  type        = string
  description = "owner/repository - scopes the GitHub OIDC trust policy."

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "Must be in owner/repository form."
  }
}

variable "github_ref" {
  type        = string
  description = <<-EOT
    The single git ref allowed to assume the CI role.

    A wildcard here is the worst mistake available in this project: on a public
    repository it would let any fork's workflow mint credentials.
  EOT
  default     = "refs/heads/main"
}

variable "ecr_repository_name" {
  type    = string
  default = "sre-demo-api"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace for the workload."
  default     = "demo"
}

variable "service_account_name" {
  type        = string
  description = "Kubernetes ServiceAccount bound to the pod IAM role."
  default     = "demo-api"
}

variable "node_instance_type" {
  type    = string
  default = "t3.large"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "owner" {
  type        = string
  description = "Owner tag value."
  default     = "frohrbaugh"
}

variable "delete_after" {
  type        = string
  description = <<-EOT
    YYYY-MM-DD. A tag, not an automation - nothing deletes anything on this
    date. Set a calendar reminder to match. See docs/plan.md section 10.5.
  EOT
}
