terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.14.0"
    }
    desec = {
      source  = "Valodim/desec"
      version = "0.3.0"
    }
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
locals {
  enable_ipv6_cluster    = true
  enable_internet_egress = true
  # Disable NAT instance, NAT gateway is enable automatically and vice versa
  # Just enable NAT instance in dev environment for saving cost
  enable_nat_instance = true
  # In production: CoreDNS should be in fargate
  enable_coredns_in_fargate = false
  # In production: Karpenter should be in fargate
  enable_karpenter_in_fargate = false
}
# Create or delete any resource outside terraform, it shoud be depended on this resource
resource "null_resource" "stable_cluster" {
  depends_on = [
    null_resource.aws_eks,
    module.eks_blueprints_addons,
  ]
}

resource "time_sleep" "eks" {
  create_duration = "1s"

  triggers = {
    cluster_name = module.eks.cluster_name
  }
}


provider "aws" {
  secret_key = var.AWS_SECRET_KEY
  access_key = var.AWS_ACCESS_KEY
  region     = var.AWS_DEFAULT_REGION
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  # The token has a time to live (TTL) of 15 minutes
  # https://aws.github.io/aws-eks-best-practices/security/docs/iam/
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = [
      "eks",
      "--region",
      var.AWS_DEFAULT_REGION,
      "get-token",
      "--cluster-name",
      time_sleep.eks.triggers.cluster_name,
    ]
    env = {
      AWS_ACCESS_KEY_ID     = var.AWS_ACCESS_KEY
      AWS_SECRET_ACCESS_KEY = var.AWS_SECRET_KEY
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  # The token has a time to live (TTL) of 15 minutes
  # https://aws.github.io/aws-eks-best-practices/security/docs/iam/
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = [
      "eks",
      "--region",
      var.AWS_DEFAULT_REGION,
      "get-token",
      "--cluster-name",
      time_sleep.eks.triggers.cluster_name,
    ]
    env = {
      AWS_ACCESS_KEY_ID     = var.AWS_ACCESS_KEY
      AWS_SECRET_ACCESS_KEY = var.AWS_SECRET_KEY
    }
  }
}
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    # The token has a time to live (TTL) of 15 minutes
    # https://aws.github.io/aws-eks-best-practices/security/docs/iam/
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args = [
        "eks",
        "--region",
        var.AWS_DEFAULT_REGION,
        "get-token",
        "--cluster-name",
        time_sleep.eks.triggers.cluster_name,
      ]
      command = "aws"
      env = {
        AWS_ACCESS_KEY_ID     = var.AWS_ACCESS_KEY
        AWS_SECRET_ACCESS_KEY = var.AWS_SECRET_KEY
      }
    }
  }
}