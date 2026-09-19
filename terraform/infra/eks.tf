module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.name
  cluster_version = var.eks_version

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.eks_public_access_cidrs

  # Grants the identity running Terraform cluster-admin, so the platform stack can deploy.
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }
  }

  node_security_group_additional_rules = {
    # The web gateway is exposed through an NLB with instance targets, which preserves
    # client source IPs, so this rule is the dashboard's client allow-list. The VPC CIDR
    # covers NLB health checks. Nodes are in private subnets: no direct internet path.
    nlb_nodeports = {
      description = "NLB clients and health checks to NodePort services"
      protocol    = "tcp"
      from_port   = 30000
      to_port     = 32767
      type        = "ingress"
      cidr_blocks = distinct(concat(var.dashboard_allowed_cidrs, [var.vpc_cidr]))
    }
  }

  eks_managed_node_groups = {
    # Stream processors, router, authz, web gateway, simulator.
    core = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.core_node_instance_types
      min_size       = 2
      max_size       = 6
      desired_size   = 3
      labels         = { workload = "core" }
    }

    # Dedicated to dashboard-api: long-lived SSE/gRPC connections are isolated from
    # Kafka consumers so node pressure or rollouts on one side don't disturb the other.
    edge = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.edge_node_instance_types
      min_size       = 2
      max_size       = 6
      desired_size   = 2
      labels         = { workload = "edge" }
      taints = {
        dedicated = {
          key    = "dedicated"
          value  = "edge"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }
}
