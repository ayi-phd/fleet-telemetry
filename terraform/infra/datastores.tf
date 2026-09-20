# ---------- ElastiCache (Redis): dedup keys + VIN -> fleet lookup ----------
resource "random_password" "redis" {
  length  = 32
  special = false
}

resource "aws_elasticache_subnet_group" "this" {
  count      = local.floci ? 0 : 1
  name       = local.name
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = local.name
  description          = "${local.name} dedup + fleet lookup"
  engine               = "redis"
  engine_version       = "7.1"
  parameter_group_name = "default.redis7"
  node_type            = var.redis_node_type
  num_cache_clusters   = local.floci ? 1 : 2
  port                 = 6379

  # Floci: CreateCacheSubnetGroup is unsupported, and a single node can't fail over.
  automatic_failover_enabled = !local.floci
  multi_az_enabled           = !local.floci
  subnet_group_name          = local.floci ? null : aws_elasticache_subnet_group.this[0].name
  security_group_ids         = [aws_security_group.redis.id]

  # An auth token requires transit encryption; both are AWS-only.
  at_rest_encryption_enabled = !local.floci
  transit_encryption_enabled = !local.floci
  auth_token                 = local.floci ? null : random_password.redis.result
  apply_immediately          = true
}

# ---------- RDS PostgreSQL: vehicle/fleet master data + RBAC grants ----------
resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = module.vpc.private_subnets
}

resource "aws_db_instance" "this" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = var.postgres_version
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "fleet"
  username = "fleetadmin"
  password = random_password.postgres.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.postgres.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  apply_immediately          = true
  skip_final_snapshot        = true # demo environment: destroy leaves nothing behind
  deletion_protection        = false
}

# ---------- OpenSearch: telemetry history ----------
resource "aws_iam_service_linked_role" "opensearch" {
  count            = var.create_opensearch_service_linked_role ? 1 : 0
  aws_service_name = "opensearchservice.amazonaws.com"
}

resource "aws_opensearch_domain" "this" {
  domain_name    = local.name
  engine_version = var.opensearch_version

  cluster_config {
    instance_type          = var.opensearch_instance_type
    instance_count         = local.floci ? 1 : 2
    zone_awareness_enabled = !local.floci
    dynamic "zone_awareness_config" {
      for_each = local.floci ? [] : [1]
      content {
        availability_zone_count = 2
      }
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = 20
  }

  # Floci: VPC-attached domains aren't expected to work, so the domain is public there
  # (fine for a single-developer local emulator with no real network exposure); IAM
  # access_policies below still restrict it to the two pod roles on both targets.
  dynamic "vpc_options" {
    for_each = local.floci ? [] : [1]
    content {
      subnet_ids         = slice(module.vpc.private_subnets, 0, 2)
      security_group_ids = [aws_security_group.opensearch.id]
    }
  }

  dynamic "encrypt_at_rest" {
    for_each = local.floci ? [] : [1]
    content {
      enabled = true
    }
  }
  dynamic "node_to_node_encryption" {
    for_each = local.floci ? [] : [1]
    content {
      enabled = true
    }
  }
  dynamic "domain_endpoint_options" {
    for_each = local.floci ? [] : [1]
    content {
      enforce_https       = true
      tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
    }
  }

  # IAM-based access: only the pod roles below may call the domain (SigV4).
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = [aws_iam_role.realtime_router.arn, aws_iam_role.dashboard_api.arn]
      }
      Action   = "es:ESHttp*"
      Resource = "arn:${data.aws_partition.current.partition}:es:${var.region}:${data.aws_caller_identity.current.account_id}:domain/${local.name}/*"
    }]
  })

  depends_on = [aws_iam_service_linked_role.opensearch]
}
