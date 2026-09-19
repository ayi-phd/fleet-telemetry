# AWS IoT Core -> MSK. Vehicles publish protobuf on "fleet/telemetry"; a topic rule
# forwards the raw binary payload (SELECT * keeps it as-is) to Kafka "raw-telemetry",
# keyed by MQTT client id (== VIN) so each vehicle's messages stay ordered in one partition.

data "aws_iot_endpoint" "ats" {
  endpoint_type = "iot:Data-ATS"
}

locals {
  arn_prefix = "arn:${data.aws_partition.current.partition}:iot:${var.region}:${data.aws_caller_identity.current.account_id}"
}

# ---- Device policy: a certificate may only connect as its own thing and publish telemetry.
resource "aws_iot_policy" "vehicle" {
  name = "${local.name}-vehicle"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "iot:Connect"
        Resource  = "${local.arn_prefix}:client/$${iot:Connection.Thing.ThingName}"
        Condition = { Bool = { "iot:Connection.Thing.IsAttached" = "true" } }
      },
      {
        Effect   = "Allow"
        Action   = "iot:Publish"
        Resource = "${local.arn_prefix}:topic/fleet/telemetry"
      }
    ]
  })
}

# ---- VPC destination: IoT Core creates ENIs in our private subnets to reach MSK.
data "aws_iam_policy_document" "iot_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["iot.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "iot_destination" {
  name               = "${local.name}-iot-vpc-destination"
  assume_role_policy = data.aws_iam_policy_document.iot_assume.json
}

resource "aws_iam_role_policy" "iot_destination" {
  role = aws_iam_role.iot_destination.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:CreateNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:CreateNetworkInterfacePermission",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeSubnets",
        "ec2:DescribeVpcs",
        "ec2:DescribeVpcAttribute",
        "ec2:DescribeSecurityGroups"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iot_topic_rule_destination" "msk" {
  enabled = true
  vpc_configuration {
    role_arn        = aws_iam_role.iot_destination.arn
    security_groups = [aws_security_group.iot_destination.id]
    subnet_ids      = module.vpc.private_subnets
    vpc_id          = module.vpc.vpc_id
  }
  depends_on = [aws_iam_role_policy.iot_destination]
}

# ---- Rule role: read the SCRAM secret at runtime and write rule errors to CloudWatch.
resource "aws_cloudwatch_log_group" "iot_rule_errors" {
  name              = "/aws/iot/${local.name}/rule-errors"
  retention_in_days = 7
}

resource "aws_iam_role" "iot_rule" {
  name               = "${local.name}-iot-rule"
  assume_role_policy = data.aws_iam_policy_document.iot_assume.json
}

resource "aws_iam_role_policy" "iot_rule" {
  role = aws_iam_role.iot_rule.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = aws_secretsmanager_secret.msk_scram.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.msk_scram.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.iot_rule_errors.arn}:*"
      }
    ]
  })
}

locals {
  # IoT substitution templates must reach AWS literally, hence "$${...}".
  scram_secret_ref = "'${aws_secretsmanager_secret.msk_scram.name}', 'SecretString'"
}

resource "aws_iot_topic_rule" "telemetry_to_msk" {
  name        = replace("${local.name}_telemetry_to_msk", "-", "_")
  description = "Forward raw protobuf vehicle telemetry to MSK raw-telemetry"
  enabled     = true
  sql         = "SELECT * FROM 'fleet/telemetry'"
  sql_version = "2016-03-23"

  kafka {
    destination_arn = aws_iot_topic_rule_destination.msk.arn
    topic           = "raw-telemetry"
    key             = "$${clientid()}"
    client_properties = {
      "bootstrap.servers"   = aws_msk_cluster.this.bootstrap_brokers_sasl_scram
      "security.protocol"   = "SASL_SSL"
      "sasl.mechanism"      = "SCRAM-SHA-512"
      "sasl.scram.username" = "$${get_secret(${local.scram_secret_ref}, 'username', '${aws_iam_role.iot_rule.arn}')}"
      "sasl.scram.password" = "$${get_secret(${local.scram_secret_ref}, 'password', '${aws_iam_role.iot_rule.arn}')}"
      "acks"                = "all"
    }
    header {
      key   = "ingest_ts"
      value = "$${timestamp()}"
    }
    header {
      key   = "mqtt_client_id"
      value = "$${clientid()}"
    }
  }

  error_action {
    cloudwatch_logs {
      log_group_name = aws_cloudwatch_log_group.iot_rule_errors.name
      role_arn       = aws_iam_role.iot_rule.arn
    }
  }

  depends_on = [aws_msk_scram_secret_association.this, aws_iam_role_policy.iot_rule]
}
