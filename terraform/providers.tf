provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# The EKS cluster already exists (built by the eks-argocd-3tier project).
# This project only adds a namespace, two secrets and one Argo CD Application to it.
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  registry   = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = concat(
      ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region],
      var.aws_profile == null ? [] : ["--profile", var.aws_profile]
    )
  }
}
