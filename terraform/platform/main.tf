locals {
  ns      = local.infra.kubernetes_namespace
  project = local.infra.cluster_name # account/region-scoped name, e.g. for IAM and Lambda
  floci   = var.target == "floci"
  image   = { for k, url in local.infra.ecr_repository_urls : k => "${url}:${var.image_tag}" }
  # One replica per service on Floci; var.replicas.* everywhere else.
  replicas = local.floci ? { for k, v in var.replicas : k => 1 } : var.replicas
}

resource "kubernetes_namespace_v1" "fleet" {
  metadata {
    name = local.ns
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

resource "random_password" "jwt" {
  length  = 64
  special = false
}

resource "random_password" "demo_users" {
  length  = 16
  special = false
}

# Credentials, injected per service via secret_key_ref (each pod only gets what it needs).
resource "kubernetes_secret_v1" "platform" {
  metadata {
    name      = "platform-secrets"
    namespace = kubernetes_namespace_v1.fleet.metadata[0].name
  }
  data = {
    KAFKA_BROKERS   = local.infra.msk_bootstrap_brokers
    KAFKA_USERNAME  = local.infra.msk_username
    KAFKA_PASSWORD  = local.infra.msk_password
    REDIS_PASSWORD  = local.infra.redis_auth_token
    POSTGRES_DSN    = local.infra.postgres_dsn
    JWT_SIGNING_KEY = random_password.jwt.result
    DEMO_PASSWORD   = random_password.demo_users.result
    # Only consumed on Floci (see realtime_router/dashboard_api's secret_env below):
    # Floci has no IRSA, so these stand in as static OpenSearch credentials there.
    AWS_ACCESS_KEY_ID     = var.floci_deploy_access_key_id
    AWS_SECRET_ACCESS_KEY = var.floci_deploy_secret_access_key
  }
}

resource "kubernetes_config_map_v1" "platform" {
  metadata {
    name      = "platform-config"
    namespace = kubernetes_namespace_v1.fleet.metadata[0].name
  }
  data = {
    AWS_REGION          = local.infra.region
    REDIS_ADDR          = local.infra.redis_address
    OPENSEARCH_ENDPOINT = local.infra.opensearch_endpoint
    RAW_TOPIC           = "raw-telemetry"
    CANONICAL_TOPIC     = "canonical-events"
    DLQ_TOPIC           = "raw-telemetry-dlq"
    INDEX_PREFIX        = "telemetry"
    # 0 on Floci: its single-node OpenSearch domain can't allocate a replica shard,
    # which would otherwise leave every index permanently yellow.
    OPENSEARCH_INDEX_REPLICAS = local.floci ? "0" : "1"
    # Floci: plaintext Kafka/Redis (no TLS support assumed until proven otherwise).
    KAFKA_TLS = local.floci ? "false" : "true"
    REDIS_TLS = local.floci ? "false" : "true"
    LOG_LEVEL = "info"
  }
}

locals {
  common = {
    namespace   = kubernetes_namespace_v1.fleet.metadata[0].name
    config_map  = kubernetes_config_map_v1.platform.metadata[0].name
    secret_name = kubernetes_secret_v1.platform.metadata[0].name
  }
  kafka_secrets = ["KAFKA_BROKERS", "KAFKA_USERNAME", "KAFKA_PASSWORD"]
  # OpenSearch credentials for realtime-router and dashboard-api. On AWS these env
  # vars are omitted entirely so the AWS SDK's default chain falls through to IRSA;
  # setting them to empty strings there would instead break IRSA outright, since the
  # SDK treats a present-but-empty AWS_ACCESS_KEY_ID as a (broken) static credential
  # rather than "unset". No IRSA on Floci (see infra/iam_pods.tf), so it uses these.
  opensearch_secret_env = local.floci ? ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"] : []
}

# ---------------- rbac-authz: users, grants, vehicle->fleet master data ----------------
module "rbac_authz" {
  source        = "./modules/service"
  name          = "rbac-authz"
  namespace     = local.common.namespace
  config_map    = local.common.config_map
  secret_name   = local.common.secret_name
  image         = local.image["rbac-authz"]
  replicas      = local.replicas.rbac_authz
  ports         = { http = 8080, grpc = 9090 }
  node_selector = { workload = "core" }
  secret_env    = ["POSTGRES_DSN", "REDIS_PASSWORD", "JWT_SIGNING_KEY", "DEMO_PASSWORD"]
  env = {
    SEED_DEMO_DATA     = "true"
    DEMO_VEHICLE_COUNT = tostring(var.simulated_vehicle_count)
  }
}

# ---------------- telemetry-processor: raw-telemetry -> canonical-events ----------------
module "telemetry_processor" {
  source        = "./modules/service"
  name          = "telemetry-processor"
  namespace     = local.common.namespace
  config_map    = local.common.config_map
  secret_name   = local.common.secret_name
  image         = local.image["telemetry-processor"]
  replicas      = local.replicas.telemetry_processor
  node_selector = { workload = "core" }
  secret_env    = concat(local.kafka_secrets, ["REDIS_PASSWORD"])
  env = {
    CONSUMER_GROUP   = "telemetry-processor"
    DEDUP_TTL        = "1h"
    TOPIC_PARTITIONS = "6"
    TOPIC_RETENTION  = "72h"
    # Floci's MSK emulation has a single broker: replication (and so min.insync.replicas)
    # can't exceed 1 there.
    TOPIC_REPLICATION         = local.floci ? "1" : "3"
    TOPIC_MIN_INSYNC_REPLICAS = local.floci ? "1" : "2"
  }
  # Fleet lookups need rbac-authz's initial Redis sync.
  depends_on = [module.rbac_authz]
}

# ---------------- realtime-router: canonical-events -> gRPC streams + OpenSearch ----------------
module "realtime_router" {
  source                 = "./modules/service"
  name                   = "realtime-router"
  service_name           = "realtime-router-headless"
  headless               = true # dashboard-api discovers and connects to every pod
  namespace              = local.common.namespace
  config_map             = local.common.config_map
  secret_name            = local.common.secret_name
  image                  = local.image["realtime-router"]
  replicas               = local.replicas.realtime_router
  ports                  = { grpc = 9090 }
  node_selector          = { workload = "core" }
  create_service_account = true # bound to the OpenSearch IAM role via IRSA (AWS only)
  service_account_annotations = local.floci ? {} : {
    "eks.amazonaws.com/role-arn" = local.infra.realtime_router_role_arn
  }
  secret_env = concat(local.kafka_secrets, local.opensearch_secret_env)
  env = {
    PUSH_GROUP    = "realtime-router-push"
    PERSIST_GROUP = "realtime-router-persist"
    PUSH_MAX_AGE  = "30s"
  }
  depends_on = [module.telemetry_processor] # topics are created by the processor
}

# ---------------- dashboard-api: gRPC client of the routers, SSE server for browsers ----------------
module "dashboard_api" {
  source                 = "./modules/service"
  name                   = "dashboard-api"
  namespace              = local.common.namespace
  config_map             = local.common.config_map
  secret_name            = local.common.secret_name
  image                  = local.image["dashboard-api"]
  replicas               = local.replicas.dashboard_api
  ports                  = { http = 8080 }
  create_service_account = true # bound to the OpenSearch IAM role via IRSA (AWS only)
  service_account_annotations = local.floci ? {} : {
    "eks.amazonaws.com/role-arn" = local.infra.dashboard_api_role_arn
  }
  secret_env    = concat(["JWT_SIGNING_KEY"], local.opensearch_secret_env)
  node_selector = { workload = "edge" }
  tolerations   = [{ key = "dedicated", value = "edge", effect = "NoSchedule" }]
  env = {
    AUTHZ_ADDR           = "dns:///rbac-authz.${local.ns}.svc.cluster.local:9090"
    ROUTER_HEADLESS_HOST = "realtime-router-headless.${local.ns}.svc.cluster.local"
    ROUTER_PORT          = "9090"
    SSE_HEARTBEAT        = "15s"
    SCOPE_REFRESH        = "60s"
  }
  depends_on = [module.rbac_authz, module.realtime_router]
}
