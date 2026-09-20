# AWS IoT Core is the device entry point. Vehicles publish protobuf on
# "fleet/telemetry"; the topic rule that forwards it to the iot-kafka-bridge Lambda
# lives in terraform/platform, because it targets a Lambda whose image is built and
# pushed between the two stacks (see PLAN.md Phase 1).

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
