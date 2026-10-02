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
  # The bare registry host: everything before the first "/" in a real repository_url
  # (whose path is "<project>/<reponame>", two segments - not one, which a previous
  # version of this output got wrong by stripping only the last segment, leaving the
  # project name doubled up when deploy.sh appended "$PROJECT/$repo" on top of it).
  # Derived instead of reconstructing AWS's DNS pattern by hand, so this is correct on
  # Floci too, whatever hostname/port style it uses (default is a
  # *.dkr.ecr.<region>.localhost:<port> hostname; see PLAN.md Phase 4 for the
  # FLOCI_SERVICES_ECR_URI_STYLE=path fallback if that doesn't work).
  value = split("/", values(aws_ecr_repository.this)[0].repository_url)[0]
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
  # Floci returns literally "localhost" for primary_endpoint_address - which is wrong
  # for a pod (it resolves to the pod's own loopback, not Floci's Redis container) -
  # confirmed on a live run (PLAN.md Phase 4). Use its real container-name hostname on
  # Floci instead (deploy.sh patches it into /etc/hosts on the EKS node, the same way
  # as for OpenSearch and the ECR registry, since Floci's containers have no embedded
  # DNS between them). AWS: unaffected; still a coalesce for the documented
  # cluster-mode-disabled quirk (floci-io/floci #2618, #2769) in case it recurs there.
  value = local.floci ? "floci-valkey-${local.name}:6379" : "${coalesce(aws_elasticache_replication_group.this.primary_endpoint_address, aws_elasticache_replication_group.this.configuration_endpoint_address)}:6379"
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
  # Floci's OpenSearch container serves plain HTTP; confirmed on a live run that pods
  # reach it at this container-name hostname on Floci's Docker network (PLAN.md Phase 4).
  value      = local.floci ? "http://floci-opensearch-${local.name}:9200" : "https://${aws_opensearch_domain.this[0].endpoint}"
  depends_on = [null_resource.opensearch_floci]
}

output "opensearch_dashboards_url" {
  description = "Reachable only from inside the VPC (e.g. kubectl port-forward via a pod). Empty on Floci: it runs only the OpenSearch engine, not the separate Dashboards UI."
  value       = local.floci ? "" : "https://${aws_opensearch_domain.this[0].dashboard_endpoint}"
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

output "telemetry_processor_role_arn" {
  description = "IRSA role for the telemetry-processor Kubernetes service account. Only exists when stream_raw=\"kinesis\" (it needs no AWS permissions at all on the msk path, same as today)."
  value       = var.stream_raw == "kinesis" ? aws_iam_role.telemetry_processor[0].arn : ""
}

output "raw_stream_name" {
  value = var.stream_raw == "kinesis" ? aws_kinesis_stream.raw_telemetry[0].name : ""
}

output "raw_stream_arn" {
  value = var.stream_raw == "kinesis" ? aws_kinesis_stream.raw_telemetry[0].arn : ""
}

output "raw_stream_endpoint" {
  description = "Floci serves Kinesis from its central gateway container, not a per-service endpoint; real AWS needs no override. Empty unless stream_raw=\"kinesis\" on Floci."
  value       = local.floci && var.stream_raw == "kinesis" ? "http://floci:4566" : ""
}

output "msk_scram_secret_arn" {
  description = "Reused by the native IoT kafka rule action's get_secret() calls (stream_raw=\"msk\", AWS only) - the same secret the Go services already authenticate with, not a new one."
  value       = local.floci ? "" : aws_secretsmanager_secret.msk_scram[0].arn
}

output "msk_scram_kms_key_arn" {
  value = local.floci ? "" : aws_kms_key.msk_scram[0].arn
}
