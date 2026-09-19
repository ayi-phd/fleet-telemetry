variable "region" {
  description = "AWS region for every resource."
  type        = string
  default     = "us-west-2"
}

variable "project" {
  description = "Name prefix for all resources (lowercase, <= 20 chars)."
  type        = string
  default     = "fleet-telemetry"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.project))
    error_message = "project must be 3-20 chars: lowercase letters, digits, hyphens."
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "single_nat_gateway" {
  description = "One NAT gateway (cheaper) instead of one per AZ (resilient)."
  type        = bool
  default     = true
}

variable "eks_version" {
  type    = string
  default = "1.34"
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS API endpoint (the machine running Terraform must be included)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "dashboard_allowed_cidrs" {
  description = "Client CIDRs allowed to open the dashboard through the public load balancer."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "core_node_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "edge_node_instance_types" {
  description = "Node group dedicated to dashboard-api (long-lived SSE connections)."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "msk_kafka_version" {
  type    = string
  default = "3.7.x"
}

variable "msk_instance_type" {
  type    = string
  default = "kafka.t3.small"
}

variable "redis_node_type" {
  type    = string
  default = "cache.t4g.small"
}

variable "postgres_version" {
  type    = string
  default = "16"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "opensearch_version" {
  type    = string
  default = "OpenSearch_2.17"
}

variable "opensearch_instance_type" {
  type    = string
  default = "t3.small.search"
}

variable "create_opensearch_service_linked_role" {
  description = "Create the account-wide OpenSearch service-linked role. deploy.sh sets this automatically."
  type        = bool
  default     = true
}

variable "kubernetes_namespace" {
  description = "Namespace the platform stack deploys into (used for Pod Identity associations)."
  type        = string
  default     = "fleet"
}
