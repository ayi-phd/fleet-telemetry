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

# Floci's own certificate generation is broken: DescribeCertificate returns the
# certificate's own ID wrapped in PEM armor instead of a real X.509 certificate
# (confirmed directly against the raw API response, PLAN.md Phase 4) - every
# vehicle-simulator connection fails immediately with "x509: malformed certificate"
# before any TLS handshake is attempted. Registering an externally-generated
# certificate instead of asking Floci to generate one doesn't work around it either:
# both RegisterCertificateWithoutCA and CreateCertificateFromCsr are broken on Floci
# too (the former is misrouted to its S3 handler entirely - confirmed via the S3-style
# error body returned; the latter hits the exact same bogus-PEM bug as the default
# path). On Floci, generate a real self-signed keypair ourselves and skip IoT Core's
# certificate registration/attachment entirely - there is no working way to register
# one there, and Floci's broker is not expected to check it anyway.
resource "tls_private_key" "sim" {
  for_each  = local.floci ? toset(local.sim_vins) : toset([])
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "sim" {
  for_each        = local.floci ? toset(local.sim_vins) : toset([])
  private_key_pem = tls_private_key.sim[each.key].private_key_pem

  subject {
    common_name = each.key
  }
  validity_period_hours = 87600 # 10 years: a throwaway local-dev credential
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "client_auth",
  ]
}

resource "aws_iot_certificate" "sim" {
  for_each = local.floci ? toset([]) : toset(local.sim_vins)
  active   = true
}

resource "aws_iot_thing_principal_attachment" "sim" {
  for_each  = local.floci ? toset([]) : toset(local.sim_vins)
  thing     = aws_iot_thing.sim[each.key].name
  principal = aws_iot_certificate.sim[each.key].arn
}

resource "aws_iot_policy_attachment" "sim" {
  for_each = local.floci ? toset([]) : toset(local.sim_vins)
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
    # Read our own generated cert on Floci rather than aws_iot_certificate's reflected
    # certificate_pem (optional+computed: safe either way, but this avoids relying on
    # AWS's registration API returning byte-identical PEM to what we registered).
    { for v in local.sim_vins : "${v}.cert.pem" => local.floci ? tls_self_signed_cert.sim[v].cert_pem : aws_iot_certificate.sim[v].certificate_pem },
    { for v in local.sim_vins : "${v}.key.pem" => local.floci ? tls_private_key.sim[v].private_key_pem : aws_iot_certificate.sim[v].private_key },
    # Amazon Root CA 1 on AWS, so the simulator doesn't fall back to system roots
    # (which don't include it). On Floci, deploy.sh fetches its real broker CA to
    # floci-ca.pem before applying this stack; try() falls back to the Amazon cert
    # (which won't verify Floci's broker) only if that hasn't happened yet.
    { "ca.pem" = local.floci ? try(file("${path.module}/floci-ca.pem"), file("${path.module}/certs/amazon-root-ca-1.pem")) : file("${path.module}/certs/amazon-root-ca-1.pem") },
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
