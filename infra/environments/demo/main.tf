################################################################################
# Network
#
# Two AZs. Nodes in private subnets, the internet-facing ALB in public subnets.
#
# ONE NAT gateway, deliberately: it is a declared demo cost tradeoff, not an
# oversight. Production would use one per AZ (so an AZ failure cannot take out
# egress for the others) and/or VPC endpoints for ECR/S3/STS to cut NAT data
# charges. See docs/plan.md section 13.4.
################################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)
  vpc_cidr = "10.42.0.0/16"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.cluster_name}-vpc"
  cidr = local.vpc_cidr
  azs  = local.azs

  # /20 per subnet: ~4090 usable addresses. The VPC CNI assigns real VPC
  # addresses to pods, so subnet sizing bounds how many pods can ever run here.
  private_subnets = [for i in range(2) : cidrsubnet(local.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(2) : cidrsubnet(local.vpc_cidr, 4, i + 8)]

  enable_nat_gateway = true
  single_nat_gateway = true # demo cost tradeoff

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Subnet discovery tags. Without these the AWS Load Balancer Controller
  # cannot find where to put the ALB, and the Ingress silently never gets an
  # address - one of the most common EKS failure modes.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

################################################################################
# EKS
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Public endpoint restricted to a single operator IP; private endpoint on so
  # in-cluster traffic never leaves the VPC.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.public_access_cidrs
  endpoint_private_access      = true

  # Without these the control plane is a black box during an incident.
  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Grant the identity running Terraform cluster-admin via an access entry
  # rather than hand-editing the aws-auth ConfigMap.
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API"

  addons = {
    # before_compute = true is LOAD-BEARING, not a style choice.
    #
    # Without it this deadlocks on a fresh cluster:
    #   - the managed node group waits for its nodes to report Ready
    #   - a node cannot report Ready without a CNI ("cni plugin not
    #     initialized" appears in the node's Ready condition)
    #   - the CNI add-on is created after the node group
    # Each waits on the other until the node group times out.
    #
    # kube-proxy gets the same treatment: Service routing is broken without
    # it, and there is no reason to schedule workloads before it exists.
    vpc-cni = {
      before_compute = true
    }
    kube-proxy = {
      before_compute = true
    }

    # CoreDNS must NOT be before_compute: it is a Deployment that needs a node
    # to schedule onto, so it can only land after the node group exists.
    coredns = {}

    # Required for EKS Pod Identity. Without this add-on the association
    # exists in AWS but no credentials are ever delivered to the pod.
    eks-pod-identity-agent = {}
  }

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND" # predictable behaviour during a live demo

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 40
            volume_type = "gp3"
            encrypted   = true
          }
        }
      }

      # IMDSv2 required, and hop limit 1 so a compromised pod cannot reach the
      # node's instance metadata and inherit the node role.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      labels = {
        workload = "demo"
      }
    }
  }
}

################################################################################
# ECR
################################################################################

resource "aws_ecr_repository" "api" {
  name = var.ecr_repository_name

  # Immutable tags: a pushed SHA can never be repointed at different bytes.
  # This is what makes "the running pod is exactly this commit" a true claim.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Demo only: lets terraform destroy remove the repo with images still in it.
  force_delete = true
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 10 most recent tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}

################################################################################
# Demo S3 object - the target of the least-privilege proof
################################################################################

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "demo" {
  bucket = "${var.cluster_name}-demo-${random_id.bucket_suffix.hex}"

  # Demo only: allows destroy with objects present.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "demo" {
  bucket                  = aws_s3_bucket.demo.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "demo" {
  bucket = aws_s3_bucket.demo.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "demo" {
  bucket = aws_s3_bucket.demo.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Synthetic. No real data of any kind appears in this project.
resource "aws_s3_object" "demo_config" {
  bucket       = aws_s3_bucket.demo.id
  key          = "config/demo.json"
  content_type = "application/json"
  content = jsonencode({
    greeting    = "hello from s3"
    environment = "demo"
    synthetic   = true
    note        = "Synthetic demo data. No PHI, no PII, no real configuration."
  })
}

# Deliberately NOT readable by the pod role. The demo proves that requesting
# this key returns AccessDenied while config/demo.json succeeds.
resource "aws_s3_object" "not_allowed" {
  bucket       = aws_s3_bucket.demo.id
  key          = "not-allowed.json"
  content_type = "application/json"
  content      = jsonencode({ note = "Out of scope for the pod role - AccessDenied is the expected result." })
}

################################################################################
# Workload identity: EKS Pod Identity
#
# Separate from the GitHub OIDC role below. These solve different problems:
# this one authenticates a POD to AWS; that one authenticates a CI RUNNER.
################################################################################

data "aws_iam_policy_document" "pod_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole", "sts:TagSession"]
  }
}

resource "aws_iam_role" "api_pod" {
  name               = "${var.cluster_name}-api-pod"
  assume_role_policy = data.aws_iam_policy_document.pod_trust.json
}

data "aws_iam_policy_document" "api_s3_read" {
  statement {
    sid    = "ReadExactlyOneDemoObject"
    effect = "Allow"
    # One action, one object ARN. Not s3:GetObject on the bucket, not s3:*.
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.demo.arn}/config/demo.json"]
  }
}

resource "aws_iam_role_policy" "api_s3_read" {
  name   = "read-one-demo-object"
  role   = aws_iam_role.api_pod.id
  policy = data.aws_iam_policy_document.api_s3_read.json
}

resource "aws_eks_pod_identity_association" "api" {
  cluster_name = module.eks.cluster_name
  # Must match the namespace/serviceaccount exactly. A mismatch here is the
  # single most common cause of AccessDenied - see runbooks/.
  namespace       = var.namespace
  service_account = var.service_account_name
  role_arn        = aws_iam_role.api_pod.arn
}

################################################################################
# CI identity: GitHub Actions via OIDC
#
# No access keys are ever created. GitHub presents a signed token; STS
# exchanges it for short-lived credentials, but only for the exact repository
# and ref named below.
################################################################################

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringEquals, not StringLike. The repository is public, so anyone can
    # fork it and open a pull request; only workflows running in the named
    # repository on the named ref can obtain a token AWS will accept.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:${var.github_ref}"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.cluster_name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

data "aws_iam_policy_document" "github_ecr_push" {
  # GetAuthorizationToken cannot be scoped to a repository - it is account
  # level by design. Everything else is scoped to this one repository.
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PushToThisRepositoryOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.api.arn]
  }
}

resource "aws_iam_role_policy" "github_ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_ecr_push.json
}
