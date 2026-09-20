# Plain resources instead of terraform-aws-modules/eks: the module fetches a TLS
# certificate from the OIDC issuer to compute an IRSA thumbprint, which Floci doesn't
# serve, and associates access policies, which Floci doesn't implement. No add-ons
# block either: EKS bootstraps the default self-managed VPC CNI, kube-proxy and
# CoreDNS on cluster/node-group creation without one.
data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${local.name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = local.name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids             = module.vpc.private_subnets
    endpoint_public_access = true
    public_access_cidrs    = var.eks_public_access_cidrs
  }

  # Grants the identity running Terraform cluster-admin, so the platform stack can
  # deploy; API_AND_CONFIG_MAP keeps the aws-auth ConfigMap path available too.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${local.name}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_node_worker" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Floci's single k3s node runs every pod itself; EKS node groups are AWS-only.
# (2.9: no explicit NodePort security group rule here — the web Service's
# loadBalancerSourceRanges already makes the in-tree NLB integration open exactly
# that range on the cluster security group; verified on the Phase 5 AWS deploy.)

# Stream processors, router, authz, web gateway, simulator.
resource "aws_eks_node_group" "core" {
  count = local.floci ? 0 : 1

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "core"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = module.vpc.private_subnets
  ami_type        = "AL2023_ARM_64_STANDARD"
  instance_types  = var.core_node_instance_types
  labels          = { workload = "core" }

  scaling_config {
    min_size     = 2
    max_size     = 6
    desired_size = 3
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_worker,
    aws_iam_role_policy_attachment.eks_node_cni,
    aws_iam_role_policy_attachment.eks_node_ecr,
  ]
}

# Dedicated to dashboard-api: long-lived SSE/gRPC connections are isolated from
# Kafka consumers so node pressure or rollouts on one side don't disturb the other.
resource "aws_eks_node_group" "edge" {
  count = local.floci ? 0 : 1

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "edge"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = module.vpc.private_subnets
  ami_type        = "AL2023_ARM_64_STANDARD"
  instance_types  = var.edge_node_instance_types
  labels          = { workload = "edge" }

  taint {
    key    = "dedicated"
    value  = "edge"
    effect = "NO_SCHEDULE"
  }

  scaling_config {
    min_size     = 2
    max_size     = 6
    desired_size = 2
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_worker,
    aws_iam_role_policy_attachment.eks_node_cni,
    aws_iam_role_policy_attachment.eks_node_ecr,
  ]
}
