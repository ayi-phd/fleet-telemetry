# No custom MSK configuration: topics are created with explicit partitions, retention
# and min.insync.replicas by platform.EnsureTopics (see internal/platform/kafka.go),
# so nothing depends on broker-wide defaults or topic auto-creation. Floci's MSK
# emulation is unlikely to implement the configuration API at all.
resource "aws_msk_cluster" "this" {
  cluster_name           = local.name
  kafka_version          = var.msk_kafka_version
  number_of_broker_nodes = local.floci ? 1 : 3

  broker_node_group_info {
    instance_type   = var.msk_instance_type
    client_subnets  = module.vpc.private_subnets
    security_groups = [aws_security_group.msk.id]
    storage_info {
      ebs_storage_info {
        volume_size = 100
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = local.floci ? "PLAINTEXT" : "TLS"
      in_cluster    = true
    }
  }

  client_authentication {
    unauthenticated = local.floci
    dynamic "sasl" {
      for_each = local.floci ? [] : [1]
      content {
        scram = true
      }
    }
  }
}

# SASL/SCRAM credentials for the Go services. AWS only: Floci is unauthenticated, and
# a SCRAM secret association is likely outside what its MSK emulation implements.
resource "random_password" "msk" {
  length  = 32
  special = false
}

resource "aws_kms_key" "msk_scram" {
  count                   = local.floci ? 0 : 1
  description             = "${local.name} MSK SCRAM secret"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_secretsmanager_secret" "msk_scram" {
  count                   = local.floci ? 0 : 1
  name                    = "AmazonMSK_${local.name}" # prefix required by MSK
  kms_key_id              = aws_kms_key.msk_scram[0].key_id
  recovery_window_in_days = 0 # allows immediate re-deploy after destroy
}

resource "aws_secretsmanager_secret_version" "msk_scram" {
  count         = local.floci ? 0 : 1
  secret_id     = aws_secretsmanager_secret.msk_scram[0].id
  secret_string = jsonencode({ username = "fleet", password = random_password.msk.result })
}

resource "aws_msk_scram_secret_association" "this" {
  count           = local.floci ? 0 : 1
  cluster_arn     = aws_msk_cluster.this.arn
  secret_arn_list = [aws_secretsmanager_secret.msk_scram[0].arn]
  depends_on      = [aws_secretsmanager_secret_version.msk_scram]
}
