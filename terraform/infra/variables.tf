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

variable "target" {
  description = "Deployment target: \"aws\" or \"floci\". Set by deploy.sh."
  type        = string
  default     = "aws"
  validation {
    condition     = contains(["aws", "floci"], var.target)
    error_message = "target must be \"aws\" or \"floci\"."
  }
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
  default = ["t4g.large"]
}

variable "edge_node_instance_types" {
  description = "Node group dedicated to dashboard-api (long-lived SSE connections)."
  type        = list(string)
  default     = ["t4g.medium"]
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
  description = "Namespace the platform stack deploys into (used in IRSA trust policies)."
  type        = string
  default     = "fleet"
}

variable "iot_endpoint_override" {
  description = "Overrides the iot_endpoint output. Floci: a pod-resolvable hostname for its IoT emulation, set by deploy.sh, since data.aws_iot_endpoint may not return one pods can reach. Empty uses the data source."
  type        = string
  default     = ""
}

variable "floci_k3s_image_dir" {
  description = "Absolute path to deploy.sh's pre-built tarballs of k3s's own system images (pause, CoreDNS, metrics-server, local-path-provisioner), set by deploy.sh before this stack's apply. Unused on AWS."
  type        = string
  default     = ""
}

variable "stream_raw" {
  description = "Raw-telemetry ingestion transport: \"msk\" or \"kinesis\". Set by deploy.sh. See PLAN.md Phase 7 - only the IoT Core -> raw stream hop switches; telemetry-processor's own output stays on MSK/Kafka regardless."
  type        = string
  default     = "msk"
  validation {
    condition     = contains(["msk", "kinesis"], var.stream_raw)
    error_message = "stream_raw must be \"msk\" or \"kinesis\"."
  }
}

variable "raw_stream_shards" {
  description = "Kinesis shard count when stream_raw=\"kinesis\", on real AWS. Floci forces 1 regardless (single-node emulation, mirroring how MSK's replication is forced down there too)."
  type        = number
  default     = 6
}
