# Demo vehicles: one IoT thing + X.509 certificate per VIN. The VIN format must match
# authz.SimVIN() in services/internal/authz/store.go (seeded into PostgreSQL).
locals {
  sim_vins = var.simulator_enabled ? [for i in range(1, var.simulated_vehicle_count + 1) : format("SIM%014d", i)] : []
}

resource "aws_iot_thing" "sim" {
  for_each = toset(local.sim_vins)
  name     = each.key
  attributes = {
    source = "simulator"
  }
}

resource "aws_iot_certificate" "sim" {
  for_each = toset(local.sim_vins)
  active   = true
}

resource "aws_iot_thing_principal_attachment" "sim" {
  for_each  = toset(local.sim_vins)
  thing     = aws_iot_thing.sim[each.key].name
  principal = aws_iot_certificate.sim[each.key].arn
}

resource "aws_iot_policy_attachment" "sim" {
  for_each = toset(local.sim_vins)
  policy   = local.infra.iot_vehicle_policy_name
  target   = aws_iot_certificate.sim[each.key].arn
}

resource "kubernetes_secret_v1" "sim_certs" {
  count = var.simulator_enabled ? 1 : 0
  metadata {
    name      = "vehicle-certs"
    namespace = local.common.namespace
  }
  data = merge(
    { for v in local.sim_vins : "${v}.cert.pem" => aws_iot_certificate.sim[v].certificate_pem },
    { for v in local.sim_vins : "${v}.key.pem" => aws_iot_certificate.sim[v].private_key },
    # Amazon Root CA 1, so the simulator doesn't fall back to system roots (which don't
    # include it). Floci-only: this is a placeholder until Phase 3's deploy.sh fetches
    # Floci's own broker CA and swaps it in here - broker TLS verification stays broken
    # on Floci until then.
    { "ca.pem" = file("${path.module}/certs/amazon-root-ca-1.pem") },
  )
}

module "vehicle_simulator" {
  count         = var.simulator_enabled ? 1 : 0
  source        = "./modules/service"
  name          = "vehicle-simulator"
  namespace     = local.common.namespace
  config_map    = local.common.config_map
  secret_name   = local.common.secret_name
  image         = local.image["vehicle-simulator"]
  replicas      = 1
  node_selector = { workload = "core" }
  secret_volume = {
    secret_name = kubernetes_secret_v1.sim_certs[0].metadata[0].name
    mount_path  = "/certs"
  }
  env = {
    IOT_ENDPOINT     = local.infra.iot_endpoint
    CERT_DIR         = "/certs"
    IOT_CA_FILE      = "/certs/ca.pem"
    PUBLISH_INTERVAL = "2s"
    DUPLICATE_RATE   = "0.03"
    CENTER_LAT       = tostring(var.simulator_center.lat)
    CENTER_LNG       = tostring(var.simulator_center.lng)
  }
  # Start publishing once the pipeline is up; on destroy, stop before certs are revoked.
  depends_on = [
    module.telemetry_processor,
    module.realtime_router,
    aws_iot_thing_principal_attachment.sim,
    aws_iot_policy_attachment.sim,
  ]
}
