output "region" {
  value = var.region
}

output "target" {
  value = var.target
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "kubernetes_namespace" {
  value = var.kubernetes_namespace
}

output "ecr_registry" {
  # Derived from a real repository URL instead of reconstructing AWS's DNS pattern by
  # hand, so this is correct on Floci too, whatever hostname/port style it uses
  # (default is a *.dkr.ecr.<region>.localhost:<port> hostname; see PLAN.md Phase 4 for
  # the FLOCI_SERVICES_ECR_URI_STYLE=path fallback if that doesn't work).
  value = join("/", slice(
    split("/", values(aws_ecr_repository.this)[0].repository_url),
    0, length(split("/", values(aws_ecr_repository.this)[0].repository_url)) - 1
  ))
}

output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "msk_bootstrap_brokers" {
  value = local.floci ? aws_msk_cluster.this.bootstrap_brokers : aws_msk_cluster.this.bootstrap_brokers_sasl_scram
}

output "msk_username" {
  value = local.floci ? "" : "fleet"
}

output "msk_password" {
  value     = local.floci ? "" : random_password.msk.result
  sensitive = true
}

output "redis_address" {
  # Floci fills only the configuration endpoint for cluster-mode-disabled replication
  # groups (floci-io/floci #2618, #2769), leaving primary_endpoint_address empty.
  value = "${coalesce(aws_elasticache_replication_group.this.primary_endpoint_address, aws_elasticache_replication_group.this.configuration_endpoint_address)}:6379"
}

output "redis_auth_token" {
  value     = local.floci ? "" : random_password.redis.result
  sensitive = true
}

output "postgres_dsn" {
  value     = "postgres://${aws_db_instance.this.username}:${random_password.postgres.result}@${aws_db_instance.this.address}:${aws_db_instance.this.port}/${aws_db_instance.this.db_name}?sslmode=${local.floci ? "disable" : "require"}"
  sensitive = true
}

output "opensearch_endpoint" {
  # Floci's OpenSearch emulation is not expected to serve HTTPS; scheme (and possibly
  # port) here is a best guess to be corrected on the first Floci run (PLAN.md Phase 4).
  value = local.floci ? "http://${aws_opensearch_domain.this.endpoint}" : "https://${aws_opensearch_domain.this.endpoint}"
}

output "opensearch_dashboards_url" {
  description = "Reachable only from inside the VPC (e.g. kubectl port-forward via a pod)."
  value       = "https://${aws_opensearch_domain.this.dashboard_endpoint}"
}

output "iot_endpoint" {
  value = var.iot_endpoint_override != "" ? var.iot_endpoint_override : data.aws_iot_endpoint.ats.endpoint_address
}

output "iot_vehicle_policy_name" {
  value = aws_iot_policy.vehicle.name
}

output "dashboard_allowed_cidrs" {
  description = "Client allow-list, applied again as loadBalancerSourceRanges on the web Service."
  value       = var.dashboard_allowed_cidrs
}

output "vpc_id" {
  description = "Used by destroy.sh to clean up load balancers and ENIs that AWS creates outside Terraform."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Used by the platform stack's iot-kafka-bridge Lambda VPC config."
  value       = module.vpc.private_subnets
}

output "realtime_router_role_arn" {
  description = "IRSA role for the realtime-router Kubernetes service account."
  value       = aws_iam_role.realtime_router.arn
}

output "dashboard_api_role_arn" {
  description = "IRSA role for the dashboard-api Kubernetes service account."
  value       = aws_iam_role.dashboard_api.arn
}
