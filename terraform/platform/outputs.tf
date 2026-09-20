locals {
  lb_ingress = kubernetes_service_v1.web.status[0].load_balancer[0].ingress[0]
}

output "dashboard_url" {
  value = "http://${coalesce(local.lb_ingress.hostname, local.lb_ingress.ip)}"
}

output "demo_users" {
  value = {
    admin          = "sees every fleet"
    north-manager  = "fleet-north only"
    south-viewer   = "fleet-south only"
    vehicle-viewer = "two individually granted vehicles"
  }
}

output "demo_password" {
  value     = random_password.demo_users.result
  sensitive = true
}

output "simulated_vins" {
  value = local.sim_vins
}

output "iot_rule_error_log_group" {
  value = aws_cloudwatch_log_group.iot_rule_errors.name
}
