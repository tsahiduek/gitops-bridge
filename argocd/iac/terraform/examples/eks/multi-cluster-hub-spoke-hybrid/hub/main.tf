provider "aws" {
  region = local.region
}
data "aws_availability_zones" "available" {}


provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
    command     = "aws"
  }
  load_config_file       = false
  apply_retry_count      = 15
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
  }
}

locals {
  name = "cluster-${local.environment}"
  environment = "control-plane"
  vpc_cidr = var.vpc_cidr
  kubernetes_version = var.kubernetes_version
  region = "us-west-2"

  addons = {
    enable_metrics_server = true # doesn't required aws resources (ie IAM)
  }

  argocd_bootstrap_app_of_apps = {
    addons = file("${path.module}/bootstrap/addons.yaml")
  }

  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/csantanapr/terraform-gitops-bridge"
  }
}

################################################################################
# GitOps Bridge: Metadata
################################################################################
module "gitops_bridge_metadata" {
  source = "../../../../modules/gitops-bridge-metadata"

  cluster_name = module.eks.cluster_name
  metadata = merge(module.eks_blueprints_addons.gitops_metadata,{
    enable_aws_argocd = true,
    metadata_aws_argocd_iam_role_arn = module.argocd_irsa.iam_role_arn,
    metadata_aws_argocd_namespace = "argocd"
  })
  environment = local.environment
  addons = local.addons
  argocd = {
    enable_argocd = false # we are going to install argocd with aws irsa
  }

}

################################################################################
# GitOps Bridge: Bootstrap
################################################################################
module "gitops_bridge_bootstrap" {
  source = "../../../../modules/gitops-bridge-bootstrap"

  argocd_cluster = module.gitops_bridge_metadata.argocd
  argocd_bootstrap_app_of_apps = local.argocd_bootstrap_app_of_apps
  argocd = {
    values = [
      <<-EOT
      controller:
        serviceAccount:
          annotations:
            eks.amazonaws.com/role-arn: ${module.argocd_irsa.iam_role_arn}
      server:
        serviceAccount:
          annotations:
            eks.amazonaws.com/role-arn: ${module.argocd_irsa.iam_role_arn}
      EOT
    ]
  }
}

################################################################################
# ArgoCD EKS Access
################################################################################
module "argocd_irsa" {
  source = "aws-ia/eks-blueprints-addon/aws"

  create_release             = false
  create_role                = true
  role_name_use_prefix       = false
  role_name                  = "${module.eks.cluster_name}-argocd-hub"
  assume_role_condition_test = "StringLike"
  create_policy = false
  role_policies = {
    ArgoCD_EKS_Policy = aws_iam_policy.irsa_policy.arn
  }
  oidc_providers = {
    this = {
      provider_arn    = module.eks.oidc_provider_arn
      namespace       = "argocd"
      service_account = "argocd-*"
    }
  }
  tags = local.tags

}

resource "aws_iam_policy" "irsa_policy" {
  name        = "${module.eks.cluster_name}-argocd-irsa"
  description = "IAM Policy for ArgoCD Hub"
  policy      = data.aws_iam_policy_document.irsa_policy.json
  tags        = local.tags
}

data "aws_iam_policy_document" "irsa_policy" {
  statement {
    effect    = "Allow"
    resources = ["*"]
    actions   = ["sts:AssumeRole"]
  }
}

################################################################################
# EKS Blueprints Addons
################################################################################
module "eks_blueprints_addons" {
  source = "github.com/csantanapr/terraform-aws-eks-blueprints-addons?ref=gitops-bridge-v2"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn
  vpc_id            = module.vpc.vpc_id

  # Using GitOps Bridge
  create_kubernetes_resources    = false

  enable_cert_manager       = true
  enable_aws_load_balancer_controller = true

  tags = local.tags
}

################################################################################
# EKS Cluster
################################################################################
#tfsec:ignore:aws-eks-enable-control-plane-logging
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.13"

  cluster_name                   = local.name
  cluster_version                = local.kubernetes_version
  cluster_endpoint_public_access = true


  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    initial = {
      instance_types = ["t3.medium"]

      min_size     = 3
      max_size     = 10
      desired_size = 3
    }
  }
  # EKS Addons
  cluster_addons = {
    vpc-cni = {
      # Specify the VPC CNI addon should be deployed before compute to ensure
      # the addon is configured before data plane compute resources are created
      # See README for further details
      before_compute = true
      most_recent    = true # To ensure access to the latest settings provided
      configuration_values = jsonencode({
        env = {
          # Reference docs https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
  }
  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}
