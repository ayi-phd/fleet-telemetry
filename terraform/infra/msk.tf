# No custom MSK configuration: topics are created with explicit partitions, retention
# and min.insync.replicas by platform.EnsureTopics (see internal/platform/kafka.go),
# so nothing depends on broker-wide defaults or topic auto-creation. Floci's MSK
# emulation is unlikely to implement the configuration API at all.
resource "aws_msk_cluster" "this" {
  cluster_name           = local.name
  kafka_version          = var.msk_kafka_version
  number_of_broker_nodes = 3

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
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  client_authentication {
    unauthenticated = false
    sasl {
      scram = true
    }
  }
}

# SASL/SCRAM credentials: used by IoT Core (via get_secret) and by the Go services.
resource "random_password" "msk" {
  length  = 32
  special = false
}

resource "aws_kms_key" "msk_scram" {
  description             = "${local.name} MSK SCRAM secret"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_secretsmanager_secret" "msk_scram" {
  name                    = "AmazonMSK_${local.name}" # prefix required by MSK
  kms_key_id              = aws_kms_key.msk_scram.key_id
  recovery_window_in_days = 0 # allows immediate re-deploy after destroy
}

resource "aws_secretsmanager_secret_version" "msk_scram" {
  secret_id     = aws_secretsmanager_secret.msk_scram.id
  secret_string = jsonencode({ username = "fleet", password = random_password.msk.result })
}

resource "aws_msk_scram_secret_association" "this" {
  cluster_arn     = aws_msk_cluster.this.arn
  secret_arn_list = [aws_secretsmanager_secret.msk_scram.arn]
  depends_on      = [aws_secretsmanager_secret_version.msk_scram]
}
