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

# k3s auto-schedules its own system pods (CoreDNS, metrics-server, the local-path
# provisioner) the moment the cluster above becomes active, and every single pod,
# including those, needs the "pause" sandbox image first - all from Docker Hub, not our
# ECR, with a cache wiped clean on every apply since Floci recreates this cluster's node
# container every time (see PLAN.md's accepted Option (c)). Confirmed on a live run that
# importing these from deploy.sh itself, right after this whole stack's apply returns,
# still isn't early enough: Terraform creates RDS/MSK/ElastiCache in parallel with this
# cluster, so "right after apply" can trail the cluster's own activation by minutes -
# long enough for those system pods to already have failed several pulls and backed
# off, so the images becoming available didn't help until an existing backoff timer
# expired. A null_resource depending on only the cluster runs concurrently with
# everything else in this apply instead, closing that gap to the minimum possible.
#
# This does contend for Docker itself with null_resource.opensearch_floci specifically
# (OpenSearch's own health-check loop polls it every 2 seconds) badly enough to make
# that loop miss its window outright on a live run - sequencing after it instead fixed
# that, but cost enough of the gap this resource exists to close that kube-system pods
# were still seen retrying for several minutes before succeeding, instead of failing
# outright. Running concurrently again and giving the OpenSearch health check more
# budget to tolerate the contention (see its own comment) is the better trade: nothing
# else running concurrently in this apply touches Docker the way these two do, so nothing
# else is at risk, and it actually closes the gap this resource exists to close instead
# of trading one regression for a smaller one. deploy.sh builds the tarballs this imports
# from, before calling apply.
resource "null_resource" "k3s_system_images_floci" {
  count      = local.floci && var.floci_k3s_image_dir != "" ? 1 : 0
  depends_on = [aws_eks_cluster.this]

  triggers = {
    cluster_id = aws_eks_cluster.this.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      container="floci-eks-${local.name}"
      for tarfile in "${var.floci_k3s_image_dir}"/*.tar; do
        [ -e "$tarfile" ] || continue
        docker cp "$tarfile" "$container:/tmp/k3s-image.tar"
        docker exec "$container" ctr -n k8s.io images import /tmp/k3s-image.tar >/dev/null
        docker exec "$container" rm -f /tmp/k3s-image.tar
      done
    EOT
  }
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
