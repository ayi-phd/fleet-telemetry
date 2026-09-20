# The IoT rule forwarding vehicle telemetry to iot-kafka-bridge. Lives here, not in
# terraform/infra, because it targets the Lambda above, which only exists once its
# image has been built and pushed (see README, "How a position report travels").
#
# The CloudWatch error action (and the log group/role it needs) is AWS-only: Floci's
# IoT rule emulation may not support it (open question, PLAN.md Phase 4).
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

resource "aws_lambda_permission" "iot" {
  statement_id  = "AllowIoTInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.iot_kafka_bridge.function_name
  principal     = "iot.amazonaws.com"
  source_arn    = aws_iot_topic_rule.telemetry_to_lambda.arn
}

resource "aws_iot_topic_rule" "telemetry_to_lambda" {
  name        = replace("${local.project}_telemetry_to_lambda", "-", "_")
  description = "Forward raw protobuf vehicle telemetry to the iot-kafka-bridge Lambda"
  enabled     = true
  sql         = "SELECT * FROM 'fleet/telemetry'"
  sql_version = "2016-03-23"

  lambda {
    function_arn = aws_lambda_function.iot_kafka_bridge.arn
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
