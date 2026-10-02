# The IoT rule forwarding vehicle telemetry into the raw stream. Lives here, not in
# terraform/infra, because on Floci it targets the Lambda (lambda.tf), which only
# exists once its image has been built and pushed (see README, "How a position
# report travels"). On AWS it routes natively instead, for either stream_raw value -
# no Lambda at all (see PLAN.md Phase 7): Floci's IoT rule engine runs native rule
# actions but never evaluates IoT SQL substitution templates (confirmed live:
# ${clientid()} and ${topic()} both arrive as the literal, unevaluated string), so
# Floci still needs the Lambda to get the VIN as a key by decoding the protobuf
# itself; real AWS's engine does evaluate them.
#
# aws_iam_role.iot_rule below is reused for every AWS-only permission this rule
# needs - the CloudWatch error action's log access, and (depending on stream_raw)
# either Kinesis PutRecord or the native kafka action's ENI/Secrets-Manager access -
# rather than one role per concern, since it's always the same principal
# (iot.amazonaws.com) assuming it for the same rule.
data "aws_iam_policy_document" "iot_assume" {
  count = local.floci ? 0 : 1
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["iot.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.infra.account_id]
    }
  }
}

resource "aws_cloudwatch_log_group" "iot_rule_errors" {
  count             = local.floci ? 0 : 1
  name              = "/aws/iot/${local.project}/rule-errors"
  retention_in_days = 7
}

resource "aws_iam_role" "iot_rule" {
  count              = local.floci ? 0 : 1
  name               = "${local.project}-iot-rule"
  assume_role_policy = data.aws_iam_policy_document.iot_assume[0].json
}

resource "aws_iam_role_policy" "iot_rule" {
  count = local.floci ? 0 : 1
  role  = aws_iam_role.iot_rule[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.iot_rule_errors[0].arn}:*"
    }]
  })
}

# ---------------- Native kinesis action (AWS + stream_raw="kinesis") ----------------
resource "aws_iam_role_policy" "iot_rule_kinesis" {
  count = !local.floci && var.stream_raw == "kinesis" ? 1 : 0
  role  = aws_iam_role.iot_rule[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kinesis:PutRecord"]
      Resource = [local.infra.raw_stream_arn]
    }]
  })
}

# ---------------- Native kafka action (AWS + stream_raw="msk") ----------------
# The rule engine creates and owns the ENIs reaching MSK directly via this VPC
# destination, replacing the Lambda's former VPC attachment (lambda.tf). Confirmed
# via AWS's own API reference: unlike an HTTP destination, a VPC destination needs no
# manual confirmation step - status moves IN_PROGRESS -> ENABLED on its own.
resource "aws_security_group" "iot_kafka_destination" {
  count       = !local.floci && var.stream_raw == "msk" ? 1 : 0
  name_prefix = "${local.project}-iot-kafka-dest-"
  description = "Native IoT kafka rule action's ENIs reaching MSK"
  vpc_id      = local.infra.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  lifecycle { create_before_destroy = true }
}

resource "aws_iot_topic_rule_destination" "kafka" {
  count   = !local.floci && var.stream_raw == "msk" ? 1 : 0
  enabled = true
  vpc_configuration {
    vpc_id          = local.infra.vpc_id
    subnet_ids      = local.infra.private_subnet_ids
    security_groups = [aws_security_group.iot_kafka_destination[0].id]
    role_arn        = aws_iam_role.iot_rule[0].arn
  }
}

resource "aws_iam_role_policy" "iot_rule_kafka_eni" {
  count = !local.floci && var.stream_raw == "msk" ? 1 : 0
  role  = aws_iam_role.iot_rule[0].id
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
        "ec2:DescribeSecurityGroups",
      ]
      Resource = "*" # AWS's own documented example policy for this action uses "*"
    }]
  })
}

# Reads the same MSK SASL/SCRAM secret the Go services already authenticate with
# (terraform/infra/msk.tf) - reused, not duplicated - via the rule's own get_secret()
# SQL calls below.
resource "aws_iam_role_policy" "iot_rule_kafka_secret" {
  count = !local.floci && var.stream_raw == "msk" ? 1 : 0
  role  = aws_iam_role.iot_rule[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [local.infra.msk_scram_secret_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [local.infra.msk_scram_kms_key_arn]
      },
    ]
  })
}

# ---------------- The rule itself ----------------
resource "aws_lambda_permission" "iot" {
  count         = local.floci ? 1 : 0
  statement_id  = "AllowIoTInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.iot_kafka_bridge[0].function_name
  principal     = "iot.amazonaws.com"
  source_arn    = aws_iot_topic_rule.telemetry_to_raw_stream.arn
}

resource "aws_iot_topic_rule" "telemetry_to_raw_stream" {
  name        = replace("${local.project}_telemetry_to_raw_stream", "-", "_")
  description = "Forward raw protobuf vehicle telemetry into the raw stream - via the iot-kafka-bridge Lambda on Floci, natively on AWS (PLAN.md Phase 7)"
  enabled     = true
  sql         = "SELECT * FROM 'fleet/telemetry'"
  sql_version = "2016-03-23"

  dynamic "lambda" {
    for_each = local.floci ? [1] : []
    content {
      function_arn = aws_lambda_function.iot_kafka_bridge[0].arn
    }
  }

  dynamic "kafka" {
    for_each = !local.floci && var.stream_raw == "msk" ? [1] : []
    content {
      destination_arn = aws_iot_topic_rule_destination.kafka[0].arn
      topic           = "raw-telemetry"
      key             = "$${clientid()}" # the simulator's MQTT client ID is the VIN
      header {
        key   = "ingest_ts"
        value = "$${timestamp()}"
      }
      client_properties = {
        "bootstrap.servers"   = local.infra.msk_bootstrap_brokers
        "security.protocol"   = "SASL_SSL"
        "sasl.mechanism"      = "SCRAM-SHA-512"
        "sasl.scram.username" = "$${get_secret('${local.infra.msk_scram_secret_arn}', 'SecretString', 'username', '${aws_iam_role.iot_rule[0].arn}')}"
        "sasl.scram.password" = "$${get_secret('${local.infra.msk_scram_secret_arn}', 'SecretString', 'password', '${aws_iam_role.iot_rule[0].arn}')}"
        "key.serializer"      = "StringSerializer"
        "value.serializer"    = "ByteBufferSerializer"
      }
    }
  }

  dynamic "kinesis" {
    for_each = !local.floci && var.stream_raw == "kinesis" ? [1] : []
    content {
      stream_name   = local.infra.raw_stream_name
      partition_key = "$${clientid()}" # the simulator's MQTT client ID is the VIN
      role_arn      = aws_iam_role.iot_rule[0].arn
    }
  }

  dynamic "error_action" {
    for_each = local.floci ? [] : [1]
    content {
      cloudwatch_logs {
        log_group_name = aws_cloudwatch_log_group.iot_rule_errors[0].name
        role_arn       = aws_iam_role.iot_rule[0].arn
      }
    }
  }
}
