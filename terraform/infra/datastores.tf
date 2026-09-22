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
  # Floci doesn't honor/report storage encryption; declaring it true there caused a
  # false->true diff Terraform treats as forcing replacement on every apply (confirmed
  # on a live run, PLAN.md Phase 4).
  storage_encrypted = !local.floci

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
# Only needed for a VPC-attached domain (OpenSearch uses it to manage ENIs in the
# customer's VPC), which is AWS-only (see the domain's vpc_options below). Floci
# rejects CreateServiceLinkedRole outright (confirmed on a live run, PLAN.md Phase 4).
resource "aws_iam_service_linked_role" "opensearch" {
  count            = (!local.floci && var.create_opensearch_service_linked_role) ? 1 : 0
  aws_service_name = "opensearchservice.amazonaws.com"
}

# AWS only. Confirmed on a live Floci run (PLAN.md Phase 4) that this resource can't be
# used there at all, for two independent reasons: Floci's DescribeDomain.Processing flag
# never clears (the create waiter always times out, though the domain itself comes up
# fine), and separately hashicorp/terraform-provider-aws has an unpatched bug
# (flattenCognitoOptions dereferences a nil CognitoOptions, which Floci's DescribeDomain
# omits) that crashes the provider on any later refresh of an existing domain. See the
# null_resource fallback below.
resource "aws_opensearch_domain" "this" {
  count          = local.floci ? 0 : 1
  domain_name    = local.name
  engine_version = var.opensearch_version

  cluster_config {
    instance_type          = var.opensearch_instance_type
    instance_count         = 2
    zone_awareness_enabled = true
    zone_awareness_config {
      availability_zone_count = 2
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = 20
  }

  vpc_options {
    subnet_ids         = slice(module.vpc.private_subnets, 0, 2)
    security_group_ids = [aws_security_group.opensearch.id]
  }

  encrypt_at_rest {
    enabled = true
  }
  node_to_node_encryption {
    enabled = true
  }
  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
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

# Floci fallback: the real OpenSearch container this creates is fully functional (a
# live run confirmed it serves requests within about a minute), but neither Terraform's
# create waiter nor any later refresh can be used against it (see above), so it's
# managed with the AWS CLI directly instead. Invoked automatically by the same
# `terraform apply`/`destroy` deploy.sh and destroy.sh already run - no new script
# (CLAUDE.md: exactly deploy.sh and destroy.sh, targets are switches inside them).
# local-exec inherits deploy.sh's environment, including the Floci AWS credentials.
resource "null_resource" "opensearch_floci" {
  count = local.floci ? 1 : 0

  triggers = {
    domain_name    = local.name
    engine_version = var.opensearch_version
    instance_type  = var.opensearch_instance_type
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      name='${local.name}'
      container="floci-opensearch-$name"
      # describe-domain is not a reliable signal for whether create-domain still needs
      # to run: confirmed on a live run that it kept reporting the domain as present
      # ("Deleted": false) well after a prior destroy had already removed the
      # container, because Floci's own delete-domain call didn't take effect until
      # called a second time - so the create step here skipped calling create-domain
      # (describe-domain "succeeded"), and the container was simply never spawned, with
      # nothing but a generic health-check timeout to show for it. Check the real
      # container's state instead, the same way the health-check loop below already
      # does. "Already exists" from create-domain is expected and tolerated: it can
      # legitimately fire when Floci's own state disagrees with the container's.
      if [ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" != "true" ]; then
        aws opensearch create-domain \
          --domain-name "$name" \
          --engine-version '${var.opensearch_version}' \
          --cluster-config 'InstanceType=${var.opensearch_instance_type},InstanceCount=1,DedicatedMasterEnabled=false,ZoneAwarenessEnabled=false' \
          --ebs-options 'EBSEnabled=true,VolumeType=gp3,VolumeSize=20' \
          >/dev/null 2>&1 || true
      fi
      for i in $(seq 1 60); do
        docker exec "$container" curl -fsS http://localhost:9200 >/dev/null 2>&1 && exit 0
        sleep 2
      done
      echo "OpenSearch container ($container) did not become healthy in time" >&2
      exit 1
    EOT
  }

  provisioner "local-exec" {
    when = destroy
    # delete-domain only tells Floci's control plane the domain is gone; the container
    # it spawned keeps running regardless (confirmed on a live destroy - PLAN.md Phase
    # 4) - remove it directly too, same as this resource's own create step does.
    command = <<-EOT
      aws opensearch delete-domain --domain-name '${self.triggers.domain_name}' >/dev/null 2>&1 || true
      docker rm -f 'floci-opensearch-${self.triggers.domain_name}' >/dev/null 2>&1 || true
    EOT
  }
}
