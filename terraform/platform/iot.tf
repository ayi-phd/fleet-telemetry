# The IoT rule forwarding vehicle telemetry to iot-kafka-bridge. Lives here, not in
# terraform/infra, because it targets the Lambda above, which only exists once its
# image has been built and pushed (see README, "How a position report travels").
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
      values   = [local.infra.account_id]
    }
  }
}

resource "aws_cloudwatch_log_group" "iot_rule_errors" {
  name              = "/aws/iot/${local.project}/rule-errors"
  retention_in_days = 7
}

resource "aws_iam_role" "iot_rule" {
  name               = "${local.project}-iot-rule"
  assume_role_policy = data.aws_iam_policy_document.iot_assume.json
}

resource "aws_iam_role_policy" "iot_rule" {
  role = aws_iam_role.iot_rule.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.iot_rule_errors.arn}:*"
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

  error_action {
    cloudwatch_logs {
      log_group_name = aws_cloudwatch_log_group.iot_rule_errors.name
      role_arn       = aws_iam_role.iot_rule.arn
    }
  }
}
