variable "image_tag" {
  description = "Tag of the images pushed by deploy.sh."
  type        = string
  default     = "latest"
}

variable "target" {
  description = "Deployment target: \"aws\" or \"floci\". Set by deploy.sh."
  type        = string
  default     = "aws"
  validation {
    condition     = contains(["aws", "floci"], var.target)
    error_message = "target must be \"aws\" or \"floci\"."
  }
}

variable "floci_deploy_access_key_id" {
  description = "Floci-local IAM access key, used as static OpenSearch credentials for realtime-router and dashboard-api since Floci's EKS emulation has no OIDC identity for IRSA. Set by deploy.sh; unused on AWS."
  type        = string
  default     = ""
}

variable "floci_deploy_secret_access_key" {
  type      = string
  default   = ""
  sensitive = true
}

variable "simulator_enabled" {
  type    = bool
  default = true
}

variable "simulated_vehicle_count" {
  description = "IoT things + certificates created for the simulator (also seeded into PostgreSQL)."
  type        = number
  default     = 12
}

variable "simulator_center" {
  description = "Where simulated vehicles drive."
  type        = object({ lat = number, lng = number })
  default     = { lat = 37.7749, lng = -122.4194 }
}

variable "replicas" {
  type = map(number)
  default = {
    telemetry_processor = 2
    realtime_router     = 2
    dashboard_api       = 2
    rbac_authz          = 2
    web                 = 2
  }
}
