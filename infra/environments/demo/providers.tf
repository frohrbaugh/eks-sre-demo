provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "eks-sre-demo"
      Environment = "demo"
      ManagedBy   = "terraform"
      Owner       = var.owner
      # Cost hygiene: makes orphaned resources findable after a partial destroy.
      DeleteAfter = var.delete_after
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}
