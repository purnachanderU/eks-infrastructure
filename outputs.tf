output "cluster_name" {

  value = module.eks.cluster_name
}


output "cluster_endpoint" {

  value = module.eks.cluster_endpoint
}


output "cluster_arn" {

  value = module.eks.cluster_arn
}


output "ecr_repository_url" {

  value = aws_ecr_repository.python_registration.repository_url
}


output "github_actions_role_arn" {

  value = aws_iam_role.github_actions.arn
}


output "ebs_csi_role_arn" {

  value = aws_iam_role.ebs_csi.arn
}


output "vpc_id" {

  value = module.vpc.vpc_id
}


output "private_subnets" {

  value = module.vpc.private_subnets
}
