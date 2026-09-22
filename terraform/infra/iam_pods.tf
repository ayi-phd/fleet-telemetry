# IRSA: pods get AWS credentials by assuming a role via their Kubernetes service
# account's OIDC-federated identity. Only the services that call OpenSearch need AWS
# permissions; everything else uses credentials injected as Kubernetes secrets by
# the platform stack.
#
# The certificate-fetch step the terraform-aws-modules/eks module normally does to
# compute this thumbprint isn't served by Floci, and AWS no longer validates the
# thumbprint against the issuer's actual chain for OIDC providers backed by a
# publicly trusted CA (which EKS's always is) - so a static, well-known placeholder
# is used on both targets instead of fetching one.
#
# AWS only: confirmed on a live Floci run (PLAN.md Phase 4) that its EKS emulation
# never populates the cluster's OIDC identity block (aws_eks_cluster.identity is
# always an empty list), so IRSA cannot be set up there at all. Floci uses a static,
# Floci-local IAM user's access key instead (injected as pod env vars by the
# platform stack); see terraform/platform/main.tf and deploy.sh.
resource "aws_iam_openid_connect_provider" "eks" {
  count           = local.floci ? 0 : 1
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
}

locals {
  opensearch_arn        = "arn:${data.aws_partition.current.partition}:es:${var.region}:${data.aws_caller_identity.current.account_id}:domain/${local.name}"
  oidc_issuer_host_path = local.floci ? "" : replace(aws_iam_openid_connect_provider.eks[0].url, "https://", "")
}

data "aws_iam_policy_document" "irsa_trust" {
  for_each = local.floci ? toset([]) : toset(["realtime-router", "dashboard-api"])

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host_path}:sub"
      values   = ["system:serviceaccount:${var.kubernetes_namespace}:${each.key}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host_path}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# Floci: these roles are still created (their ARNs are the OpenSearch domain's
# access_policies principals below, unchanged on both targets), but nothing ever
# assumes them there - the account root placeholder trust is never exercised.
data "aws_iam_policy_document" "floci_role_trust" {
  count = local.floci ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "realtime_router" {
  name               = "${local.name}-realtime-router"
  assume_role_policy = local.floci ? data.aws_iam_policy_document.floci_role_trust[0].json : data.aws_iam_policy_document.irsa_trust["realtime-router"].json
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

resource "aws_iam_role" "dashboard_api" {
  name               = "${local.name}-dashboard-api"
  assume_role_policy = local.floci ? data.aws_iam_policy_document.floci_role_trust[0].json : data.aws_iam_policy_document.irsa_trust["dashboard-api"].json
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
