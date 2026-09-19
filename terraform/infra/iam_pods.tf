# EKS Pod Identity: pods get AWS credentials through their Kubernetes service account.
# Only the services that call OpenSearch need AWS permissions; everything else uses
# credentials injected as Kubernetes secrets by the platform stack.

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

locals {
  opensearch_arn = "arn:${data.aws_partition.current.partition}:es:${var.region}:${data.aws_caller_identity.current.account_id}:domain/${local.name}"
}

resource "aws_iam_role" "realtime_router" {
  name               = "${local.name}-realtime-router"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy" "realtime_router" {
  role = aws_iam_role.realtime_router.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["es:ESHttpGet", "es:ESHttpHead", "es:ESHttpPost", "es:ESHttpPut"]
      Resource = ["${local.opensearch_arn}/*"]
    }]
  })
}

resource "aws_eks_pod_identity_association" "realtime_router" {
  cluster_name    = module.eks.cluster_name
  namespace       = var.kubernetes_namespace
  service_account = "realtime-router"
  role_arn        = aws_iam_role.realtime_router.arn
}

resource "aws_iam_role" "dashboard_api" {
  name               = "${local.name}-dashboard-api"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy" "dashboard_api" {
  role = aws_iam_role.dashboard_api.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["es:ESHttpGet", "es:ESHttpHead", "es:ESHttpPost"] # search is a POST
      Resource = ["${local.opensearch_arn}/*"]
    }]
  })
}

resource "aws_eks_pod_identity_association" "dashboard_api" {
  cluster_name    = module.eks.cluster_name
  namespace       = var.kubernetes_namespace
  service_account = "dashboard-api"
  role_arn        = aws_iam_role.dashboard_api.arn
}
