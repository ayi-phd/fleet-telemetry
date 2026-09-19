# Reusable Deployment (+ optional Service, ServiceAccount, PDB) for the Go microservices.
terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}

variable "name" { type = string }
variable "namespace" { type = string }
variable "image" { type = string }
variable "replicas" {
  type    = number
  default = 2
}
variable "ports" {
  description = "Named container ports also exposed on the Service."
  type        = map(number)
  default     = {}
}
variable "headless" {
  description = "Create a headless Service (per-pod DNS A records) instead of ClusterIP."
  type        = bool
  default     = false
}
variable "service_name" {
  type    = string
  default = null
}
variable "env" {
  type    = map(string)
  default = {}
}
variable "config_map" { type = string }
variable "secret_name" { type = string }
variable "secret_env" {
  description = "Keys copied from the platform secret into env vars of the same name."
  type        = list(string)
  default     = []
}
variable "create_service_account" {
  type    = bool
  default = false
}
variable "node_selector" {
  type    = map(string)
  default = { workload = "core" }
}
variable "tolerations" {
  type = list(object({ key = string, value = string, effect = string }))
  default = []
}
variable "secret_volume" {
  type    = object({ secret_name = string, mount_path = string })
  default = null
}
variable "cpu_request" {
  type    = string
  default = "100m"
}
variable "memory_request" {
  type    = string
  default = "128Mi"
}
variable "memory_limit" {
  type    = string
  default = "512Mi"
}
variable "termination_grace_seconds" {
  type    = number
  default = 30
}

locals {
  labels = { app = var.name, "app.kubernetes.io/part-of" = "fleet-telemetry" }
}

resource "kubernetes_service_account_v1" "this" {
  count = var.create_service_account ? 1 : 0
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
}

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = var.replicas
    selector {
      match_labels = { app = var.name }
    }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8081"
        }
      }

      spec {
        service_account_name             = var.create_service_account ? kubernetes_service_account_v1.this[0].metadata[0].name : null
        node_selector                    = var.node_selector
        termination_grace_period_seconds = var.termination_grace_seconds

        dynamic "toleration" {
          for_each = var.tolerations
          content {
            key      = toleration.value.key
            operator = "Equal"
            value    = toleration.value.value
            effect   = toleration.value.effect
          }
        }

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = { app = var.name }
          }
        }

        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          run_as_group    = 65532
          fs_group        = 65532 # makes mounted secret files readable by the non-root user
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name              = var.name
          image             = var.image
          image_pull_policy = "Always"

          dynamic "port" {
            for_each = merge(var.ports, { ops = 8081 })
            content {
              name           = port.key
              container_port = port.value
            }
          }

          env {
            name = "POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }

          dynamic "env" {
            for_each = var.env
            content {
              name  = env.key
              value = env.value
            }
          }

          dynamic "env" {
            for_each = toset(var.secret_env)
            content {
              name = env.value
              value_from {
                secret_key_ref {
                  name = var.secret_name
                  key  = env.value
                }
              }
            }
          }

          env_from {
            config_map_ref {
              name = var.config_map
            }
          }

          dynamic "volume_mount" {
            for_each = var.secret_volume == null ? [] : [var.secret_volume]
            content {
              name       = "secret-files"
              mount_path = volume_mount.value.mount_path
              read_only  = true
            }
          }

          resources {
            requests = { cpu = var.cpu_request, memory = var.memory_request }
            limits   = { memory = var.memory_limit }
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = "ops"
            }
            period_seconds    = 10
            failure_threshold = 3
          }

          readiness_probe {
            http_get {
              path = "/readyz"
              port = "ops"
            }
            period_seconds    = 5
            failure_threshold = 2
          }

          startup_probe {
            http_get {
              path = "/healthz"
              port = "ops"
            }
            period_seconds    = 5
            failure_threshold = 60
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        dynamic "volume" {
          for_each = var.secret_volume == null ? [] : [var.secret_volume]
          content {
            name = "secret-files"
            secret {
              secret_name  = volume.value.secret_name
              default_mode = "0440"
            }
          }
        }
      }
    }
  }

  timeouts {
    create = "15m"
    update = "15m"
  }
}

resource "kubernetes_service_v1" "this" {
  count = length(var.ports) > 0 ? 1 : 0
  metadata {
    name      = coalesce(var.service_name, var.name)
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    selector   = { app = var.name }
    cluster_ip = var.headless ? "None" : null
    dynamic "port" {
      for_each = var.ports
      content {
        name        = port.key
        port        = port.value
        target_port = port.key
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "this" {
  count = var.replicas > 1 ? 1 : 0
  metadata {
    name      = var.name
    namespace = var.namespace
  }
  spec {
    max_unavailable = "1"
    selector {
      match_labels = { app = var.name }
    }
  }
}

output "service_name" {
  value = length(kubernetes_service_v1.this) > 0 ? kubernetes_service_v1.this[0].metadata[0].name : null
}
