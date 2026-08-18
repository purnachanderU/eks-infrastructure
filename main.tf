provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  name = var.cluster_name

  common_tags = {
    Project   = "python-registration"
    ManagedBy = "Terraform"
  }
}


# ---------------------------------------------------------
# VPC
# ---------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = "${local.name}-vpc"

  cidr = "10.0.0.0/16"

  azs = [
    "us-east-1a",
    "us-east-1b"
  ]

  public_subnets = [
    "10.0.101.0/24",
    "10.0.102.0/24"
  ]

  private_subnets = [
    "10.0.1.0/24",
    "10.0.2.0/24"
  ]

  enable_nat_gateway = true

  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.common_tags
}


# ---------------------------------------------------------
# ECR
# ---------------------------------------------------------

resource "aws_ecr_repository" "python_registration" {

  name = "python-registration"

  image_scanning_configuration {
    scan_on_push = true
  }

  image_tag_mutability = "IMMUTABLE"

  tags = local.common_tags
}


# ---------------------------------------------------------
# GitHub OIDC Provider
# ---------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {

  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  tags = local.common_tags
}


# ---------------------------------------------------------
# GitHub Actions IAM Role
# ---------------------------------------------------------

data "aws_iam_policy_document" "github_assume_role" {

  statement {

    effect = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {
      type = "Federated"

      identifiers = [
        aws_iam_openid_connect_provider.github.arn
      ]
    }

    condition {

      test = "StringEquals"

      variable = "token.actions.githubusercontent.com:aud"

      values = [
        "sts.amazonaws.com"
      ]
    }

    condition {

      test = "StringLike"

      variable = "token.actions.githubusercontent.com:sub"

      values = [
        "repo:${var.github_repository}:*"
      ]
    }
  }
}


resource "aws_iam_role" "github_actions" {

  name = "${local.name}-github-actions"

  assume_role_policy = data.aws_iam_policy_document.github_assume_role.json

  tags = local.common_tags
}


# ---------------------------------------------------------
# ECR permissions for GitHub Actions
# ---------------------------------------------------------

resource "aws_iam_policy" "github_ecr" {

  name = "${local.name}-github-ecr"

  policy = jsonencode({

    Version = "2012-10-17"

    Statement = [

      {
        Effect = "Allow"

        Action = [
          "ecr:GetAuthorizationToken"
        ]

        Resource = "*"
      },

      {
        Effect = "Allow"

        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]

        Resource = aws_ecr_repository.python_registration.arn
      }

    ]
  })
}


resource "aws_iam_role_policy_attachment" "github_ecr" {

  role = aws_iam_role.github_actions.name

  policy_arn = aws_iam_policy.github_ecr.arn
}


# ---------------------------------------------------------
# EKS permissions for GitHub Actions
# ---------------------------------------------------------

resource "aws_iam_policy" "github_eks" {

  name = "${local.name}-github-eks"

  policy = jsonencode({

    Version = "2012-10-17"

    Statement = [

      {
        Effect = "Allow"

        Action = [
          "eks:DescribeCluster"
        ]

        Resource = "*"
      }

    ]
  })
}


resource "aws_iam_role_policy_attachment" "github_eks" {

  role = aws_iam_role.github_actions.name

  policy_arn = aws_iam_policy.github_eks.arn
}


# ---------------------------------------------------------
# EKS Cluster
# ---------------------------------------------------------

module "eks" {

  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.0"

  name = local.name

  kubernetes_version = var.kubernetes_version

  endpoint_public_access = true

  endpoint_public_access_cidrs = [
    "0.0.0.0/0"
  ]

  authentication_mode = "API_AND_CONFIG_MAP"

  enable_cluster_creator_admin_permissions = true

  vpc_id = module.vpc.vpc_id

  subnet_ids = module.vpc.private_subnets

  control_plane_subnet_ids = module.vpc.private_subnets


  # -------------------------------------------------------
  # EKS Addons
  # -------------------------------------------------------

  addons = {

    coredns = {
      most_recent = true
    }

    kube-proxy = {
      most_recent = true
    }

    vpc-cni = {
      most_recent = true

      before_compute = true
    }

    eks-pod-identity-agent = {
      most_recent = true
    }

    aws-ebs-csi-driver = {
      most_recent = true
    }
  }


  # -------------------------------------------------------
  # Managed Node Group
  # -------------------------------------------------------

  eks_managed_node_groups = {

    default = {

      name = "eksdemo-ng"

      instance_types = [
        "t3.small"
      ]

      min_size = 1

      max_size = 2

      desired_size = 2

      disk_size = 20

      capacity_type = "ON_DEMAND"

      subnet_ids = module.vpc.private_subnets

      labels = {
        Environment = "shared"
      }
    }
  }


  # -------------------------------------------------------
  # GitHub Actions EKS access
  # -------------------------------------------------------

  access_entries = {

    github_actions = {

      principal_arn = aws_iam_role.github_actions.arn

      policy_associations = {

        admin = {

          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

          access_scope = {

            type = "cluster"
          }
        }
      }
    }
  }


  tags = local.common_tags
}
