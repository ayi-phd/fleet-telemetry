# iot-kafka-bridge: the container-image Lambda IoT Core invokes for every telemetry
# message. It reads only the VIN and republishes the original protobuf bytes to MSK,
# unmodified, keyed by VIN (see services/cmd/iot-kafka-bridge and PLAN.md Phase 1).
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "iot_kafka_bridge" {
  name               = "${local.project}-iot-kafka-bridge"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# On AWS the function runs inside the VPC to reach MSK privately, which needs ENI
# permissions. Floci does not attach the function to a VPC, so it only needs log access.
resource "aws_iam_role_policy_attachment" "iot_kafka_bridge_vpc" {
  count      = local.floci ? 0 : 1
  role       = aws_iam_role.iot_kafka_bridge.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "iot_kafka_bridge_logs" {
  count      = local.floci ? 1 : 0
  role       = aws_iam_role.iot_kafka_bridge.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_security_group" "iot_kafka_bridge" {
  count       = local.floci ? 0 : 1
  name_prefix = "${local.project}-iot-kafka-bridge-"
  description = "iot-kafka-bridge Lambda ENIs reaching MSK"
  vpc_id      = local.infra.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  lifecycle { create_before_destroy = true }
}

# Async IoT invocations that exhaust their retries land here instead of being lost.
# AWS-only: Floci's Lambda emulation is not expected to support event destinations.
resource "aws_sqs_queue" "iot_kafka_bridge_dlq" {
  count                     = local.floci ? 0 : 1
  name                      = "${local.project}-iot-kafka-bridge-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_iam_role_policy" "iot_kafka_bridge_dlq" {
  count = local.floci ? 0 : 1
  role  = aws_iam_role.iot_kafka_bridge.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.iot_kafka_bridge_dlq[0].arn
    }]
  })
}

resource "aws_lambda_function" "iot_kafka_bridge" {
  function_name = "${local.project}-iot-kafka-bridge"
  role          = aws_iam_role.iot_kafka_bridge.arn
  package_type  = "Image"
  image_uri     = local.image["iot-kafka-bridge"]
  architectures = ["arm64"]
  timeout       = 10
  memory_size   = 256

  dynamic "vpc_config" {
    for_each = local.floci ? [] : [1]
    content {
      subnet_ids         = local.infra.private_subnet_ids
      security_group_ids = [aws_security_group.iot_kafka_bridge[0].id]
    }
  }

  environment {
    variables = {
      RAW_TOPIC      = "raw-telemetry"
      KAFKA_BROKERS  = local.infra.msk_bootstrap_brokers
      KAFKA_USERNAME = local.infra.msk_username
      KAFKA_PASSWORD = local.infra.msk_password
      KAFKA_TLS      = local.floci ? "false" : "true"
      LOG_LEVEL      = "info"
    }
  }
}

resource "aws_lambda_function_event_invoke_config" "iot_kafka_bridge" {
  count         = local.floci ? 0 : 1
  function_name = aws_lambda_function.iot_kafka_bridge.function_name
  destination_config {
    on_failure {
      destination = aws_sqs_queue.iot_kafka_bridge_dlq[0].arn
    }
  }
}
