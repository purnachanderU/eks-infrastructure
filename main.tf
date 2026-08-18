# =========================================================
# PROVIDER
# =========================================================

provider "aws" {
  region = var.aws_region
}


# =========================================================
# DATA
# =========================================================

data "aws_caller_identity" "current" {}


# =========================================================
# LOCALS
# =========================================================

locals {

  name = var.cluster_name

  common_tags = {
    Project  = "python-registration"
    ManagedBy = "Terraform"
  }
}


# =========================================================
# VPC
# =========================================================

module "vpc" {

  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = "${local.name}-vpc"

  cidr = "10.0.0.0/16"

  azs = [
    "us-east-1a",
    "us-east-1b"
  ]

  # -------------------------------------------------------
  # Public Subnets
  # -------------------------------------------------------

  public_subnets = [
    "10.0.101.0/24",
    "10.0.102.0/24"
  ]

  # -------------------------------------------------------
  # Private Subnets
  # -------------------------------------------------------

  private_subnets = [
    "10.0.1.0/24",
    "10.0.2.0/24"
  ]

  # -------------------------------------------------------
  # NAT Gateway
  # -------------------------------------------------------

  enable_nat_gateway = true
  single_nat_gateway = true

  # -------------------------------------------------------
  # DNS
  # -------------------------------------------------------

  enable_dns_hostnames = true
  enable_dns_support   = true

  # -------------------------------------------------------
  # Kubernetes subnet tags
  # -------------------------------------------------------

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.common_tags
}


# =========================================================
# ECR REPOSITORY
# =========================================================

resource "aws_ecr_repository" "python_registration" {

  name = "python-registration"

  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}


# =========================================================
# GITHUB OIDC PROVIDER
# =========================================================

resource "aws_iam_openid_connect_provider" "github" {

  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  tags = local.common_tags
}


# =========================================================
# GITHUB ACTIONS TRUST POLICY
# =========================================================

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

    # GitHub audience
    condition {

      test = "StringEquals"

      variable = "token.actions.githubusercontent.com:aud"

      values = [
        "sts.amazonaws.com"
      ]
    }

    # Only your GitHub repository
    condition {

      test = "StringLike"

      variable = "token.actions.githubusercontent.com:sub"

      values = [
        "repo:${var.github_repository}:*"
      ]
    }
  }
}


# =========================================================
# GITHUB ACTIONS IAM ROLE
# =========================================================

resource "aws_iam_role" "github_actions" {

  name = "${local.name}-github-actions"

  assume_role_policy = data.aws_iam_policy_document.github_assume_role.json

  tags = local.common_tags
}


# =========================================================
# GITHUB ACTIONS ECR POLICY
# =========================================================

resource "aws_iam_policy" "github_ecr" {

  name = "${local.name}-github-ecr"

  policy = jsonencode({

    Version = "2012-10-17"

    Statement = [

      # ECR authentication
      {
        Effect = "Allow"

        Action = [
          "ecr:GetAuthorizationToken"
        ]

        Resource = "*"
      },

      # Push image
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


# =========================================================
# GITHUB ACTIONS EKS IAM POLICY
# =========================================================

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


# =========================================================
# EKS CLUSTER
# =========================================================

module "eks" {

  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.0"

  name = local.name

  kubernetes_version = var.kubernetes_version

  # -------------------------------------------------------
  # EKS API endpoint
  # -------------------------------------------------------

  endpoint_public_access = true

  # For learning/lab environment.
  # In production, restrict this to your corporate/VPN IP.
  endpoint_public_access_cidrs = [
    "0.0.0.0/0"
  ]

  # -------------------------------------------------------
  # Authentication
  # -------------------------------------------------------

  authentication_mode = "API_AND_CONFIG_MAP"

  enable_cluster_creator_admin_permissions = true

  # -------------------------------------------------------
  # Network
  # -------------------------------------------------------

  vpc_id = module.vpc.vpc_id

  subnet_ids = module.vpc.private_subnets

  control_plane_subnet_ids = module.vpc.private_subnets


  # =======================================================
  # EKS ADDONS
  # =======================================================

  addons = {

    # -----------------------------------------------------
    # CoreDNS
    # -----------------------------------------------------

    coredns = {
      most_recent = true
    }

    # -----------------------------------------------------
    # kube-proxy
    # -----------------------------------------------------

    kube-proxy = {
      most_recent = true
    }

    # -----------------------------------------------------
    # VPC CNI
    # -----------------------------------------------------

    vpc-cni = {

      most_recent = true

      before_compute = true
    }

    # -----------------------------------------------------
    # EKS Pod Identity Agent
    # -----------------------------------------------------

    eks-pod-identity-agent = {
      most_recent = true
    }

    # IMPORTANT:
    # Do NOT put aws-ebs-csi-driver here.
    #
    # We create it separately below after the
    # Pod Identity association is created.
  }


  # =======================================================
  # MANAGED NODE GROUP
  # =======================================================

  eks_managed_node_groups = {

    default = {

      name = "eksdemo-ng"

      instance_types = [
        "m7i-flex.large"
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


  # =======================================================
  # GITHUB ACTIONS EKS ACCESS
  # =======================================================

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


# =========================================================
# EBS CSI DRIVER IAM ROLE
# =========================================================

data "aws_iam_policy_document" "ebs_csi_assume_role" {

  statement {

    effect = "Allow"

    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]

    principals {

      type = "Service"

      identifiers = [
        "pods.eks.amazonaws.com"
      ]
    }
  }
}


resource "aws_iam_role" "ebs_csi" {

  name = "${local.name}-ebs-csi-role"

  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json

  tags = local.common_tags
}


# =========================================================
# EBS CSI IAM POLICY
# =========================================================

resource "aws_iam_role_policy_attachment" "ebs_csi" {

  role = aws_iam_role.ebs_csi.name

  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}


# =========================================================
# EKS POD IDENTITY ASSOCIATION
# =========================================================

resource "aws_eks_pod_identity_association" "ebs_csi" {

  cluster_name = module.eks.cluster_name
  namespace = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn = aws_iam_role.ebs_csi.arn

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.ebs_csi
  ]
}
# =========================================================
# EBS CSI DRIVER EKS ADDON
# =========================================================

resource "aws_eks_addon" "ebs_csi" {

  cluster_name = module.eks.cluster_name

  addon_name = "aws-ebs-csi-driver"

  most_recent = true

  depends_on = [
    aws_eks_pod_identity_association.ebs_csi
  ]
}
