output "region" {
  value = var.region
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
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "msk_bootstrap_brokers_scram" {
  value = aws_msk_cluster.this.bootstrap_brokers_sasl_scram
}

output "msk_username" {
  value = "fleet"
}

output "msk_password" {
  value     = random_password.msk.result
  sensitive = true
}

output "redis_address" {
  # Floci fills only the configuration endpoint for cluster-mode-disabled replication
  # groups (floci-io/floci #2618, #2769), leaving primary_endpoint_address empty.
  value = "${coalesce(aws_elasticache_replication_group.this.primary_endpoint_address, aws_elasticache_replication_group.this.configuration_endpoint_address)}:6379"
}

output "redis_auth_token" {
  value     = random_password.redis.result
  sensitive = true
}

output "postgres_dsn" {
  value     = "postgres://${aws_db_instance.this.username}:${random_password.postgres.result}@${aws_db_instance.this.address}:${aws_db_instance.this.port}/${aws_db_instance.this.db_name}?sslmode=require"
  sensitive = true
}

output "opensearch_endpoint" {
  value = "https://${aws_opensearch_domain.this.endpoint}"
}

output "opensearch_dashboards_url" {
  description = "Reachable only from inside the VPC (e.g. kubectl port-forward via a pod)."
  value       = "https://${aws_opensearch_domain.this.dashboard_endpoint}"
}

output "iot_endpoint" {
  value = data.aws_iot_endpoint.ats.endpoint_address
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
