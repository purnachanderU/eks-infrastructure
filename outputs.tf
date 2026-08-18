output "eks_cluster_name" {

  value = module.eks.cluster_name
}


output "eks_cluster_endpoint" {

  value = module.eks.cluster_endpoint
}


output "ecr_repository_url" {

  value = aws_ecr_repository.python_registration.repository_url
}


output "github_actions_role_arn" {

  value = aws_iam_role.github_actions.arn
}


output "vpc_id" {

  value = module.vpc.vpc_id
}


output "private_subnets" {

  value = module.vpc.private_subnets
}
