# iot-kafka-bridge: the container-image Lambda IoT Core invokes for every telemetry
# message, on Floci only (see terraform/platform/iot.tf and PLAN.md Phase 7). Real
# AWS's IoT rule engine evaluates substitution templates correctly, so it routes
# directly into the raw stream with a native rule action instead - no Lambda needed
# there, for either stream_raw value. Floci's rule engine runs native actions but
# never evaluates substitution templates (confirmed live: ${clientid()}/${topic()}
# both arrive as the literal, unevaluated string), so it still needs this Lambda to
# decode the protobuf itself and get the VIN as a key.
#
# Reads only the VIN and republishes the original protobuf bytes unmodified, keyed by
# VIN, to whichever raw stream STREAM_RAW selects (see services/cmd/iot-kafka-bridge).
data "aws_iam_policy_document" "lambda_assume" {
  count = local.floci ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "iot_kafka_bridge" {
  count              = local.floci ? 1 : 0
  name               = "${local.project}-iot-kafka-bridge"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume[0].json
}

# No VPC attachment needed any more: this Lambda only runs on Floci now, and Floci
# never attaches Lambdas to a VPC (see PLAN.md Phase 3/4). Real AWS's former need for
# VPC access (to reach MSK privately) no longer applies, since AWS doesn't run this
# Lambda at all - the native kafka rule action's own VPC destination (iot.tf) replaces
# it. The on-failure SQS destination and its event-invoke-config were AWS-only for the
# same reason and are removed entirely here, not just gated off.
resource "aws_iam_role_policy_attachment" "iot_kafka_bridge_logs" {
  count      = local.floci ? 1 : 0
  role       = aws_iam_role.iot_kafka_bridge[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "iot_kafka_bridge" {
  count         = local.floci ? 1 : 0
  function_name = "${local.project}-iot-kafka-bridge"
  role          = aws_iam_role.iot_kafka_bridge[0].arn
  package_type  = "Image"
  image_uri     = local.image["iot-kafka-bridge"]
  architectures = ["arm64"]
  timeout       = 10
  memory_size   = 256

  environment {
    variables = merge(
      {
        STREAM_RAW        = var.stream_raw
        RAW_TOPIC         = "raw-telemetry"
        RAW_STREAM_NAME   = local.infra.raw_stream_name
        KAFKA_BROKERS     = local.infra.msk_bootstrap_brokers
        KAFKA_USERNAME    = local.infra.msk_username
        KAFKA_PASSWORD    = local.infra.msk_password
        KAFKA_TLS         = "false" # this Lambda only ever runs on Floci now
        LOG_LEVEL         = "info"
        FLOCI_EXTRA_HOSTS = var.floci_extra_hosts
      },
      # Kinesis mode needs an AWS SDK client: Floci has no IRSA (see infra/iam_pods.tf),
      # so it authenticates with the same static Floci-local IAM user's credentials
      # used elsewhere (see main.tf's floci_aws_secret_env), and needs an explicit
      # endpoint override since Floci serves Kinesis from its central gateway
      # container, not a per-service endpoint.
      var.stream_raw == "kinesis" ? {
        AWS_ACCESS_KEY_ID        = var.floci_deploy_access_key_id
        AWS_SECRET_ACCESS_KEY    = var.floci_deploy_secret_access_key
        AWS_ENDPOINT_URL_KINESIS = local.infra.raw_stream_endpoint
        AWS_REGION               = local.infra.region
      } : {}
    )
  }
}
