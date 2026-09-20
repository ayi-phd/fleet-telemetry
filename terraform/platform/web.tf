# nginx serves the React build and reverse-proxies /api (dashboard-api, SSE-aware)
# and /auth, /admin (rbac-authz). Exposed through an internet-facing NLB.
resource "kubernetes_deployment_v1" "web" {
  metadata {
    name      = "web"
    namespace = local.common.namespace
    labels    = { app = "web" }
  }
  spec {
    replicas = local.replicas.web
    selector {
      match_labels = { app = "web" }
    }
    template {
      metadata {
        labels = { app = "web" }
      }
      spec {
        # Preferred, not required: Floci's single k3s node carries no "workload" label.
        affinity {
          node_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 50
              preference {
                match_expressions {
                  key      = "workload"
                  operator = "In"
                  values   = ["core"]
                }
              }
            }
          }
        }
        security_context {
          run_as_non_root = true
          run_as_user     = 101
          run_as_group    = 101
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name              = "web"
          image             = local.image["web"]
          image_pull_policy = "Always"
          port {
            name           = "http"
            container_port = 8080
          }
          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { memory = "256Mi" }
          }
          readiness_probe {
            http_get {
              path = "/nginx-health"
              port = "http"
            }
            period_seconds = 5
          }
          liveness_probe {
            http_get {
              path = "/nginx-health"
              port = "http"
            }
            period_seconds = 10
          }
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }
  # nginx resolves upstream Services at start-up.
  depends_on = [module.dashboard_api, module.rbac_authz]
}

resource "kubernetes_service_v1" "web" {
  metadata {
    name      = "web"
    namespace = local.common.namespace
    annotations = local.floci ? {} : {
      "service.beta.kubernetes.io/aws-load-balancer-type"                              = "nlb"
      "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
    }
  }
  spec {
    # Floci's k3s has no in-tree NLB integration; deploy.sh prints a port-forward
    # command instead of a URL for it.
    type     = local.floci ? "NodePort" : "LoadBalancer"
    selector = { app = "web" }
    # The NLB preserves client IPs, so allow-listing happens on the node security group.
    # The in-tree NLB integration opens the NodePort to whatever this list says
    # (0.0.0.0/0 when empty), so it must mirror the infra allow-list exactly.
    load_balancer_source_ranges = local.floci ? null : local.infra.dashboard_allowed_cidrs
    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
  wait_for_load_balancer = !local.floci
  timeouts {
    create = "15m"
  }
}
