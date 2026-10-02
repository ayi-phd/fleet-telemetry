# The raw stream's Kinesis alternative to MSK (see variables.tf's stream_raw and
# PLAN.md Phase 7). Unlike the Kafka topic it replaces (raw-telemetry, created at
# runtime by telemetry-processor's EnsureTopics), this is a real Terraform resource:
# a Kinesis stream is squarely "an AWS resource" under this repo's "every AWS
# resource in Terraform" rule in a way a Kafka topic isn't.
#
# Confirmed live against Floci: create-stream/put-record/get-shard-iterator/
# get-records/delete-stream all round-trip correctly against its emulated data-plane
# API, so this needs no Floci-specific branching beyond shard count.
resource "aws_kinesis_stream" "raw_telemetry" {
  count       = var.stream_raw == "kinesis" ? 1 : 0
  name        = "${local.name}-raw-telemetry"
  shard_count = local.floci ? 1 : var.raw_stream_shards
}
