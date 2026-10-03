package platform

import (
	"context"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/kinesis"
	"github.com/aws/aws-sdk-go-v2/service/kinesis/types"
)

// Kinesis is a thin wrapper around the AWS SDK v2 Kinesis client, used for the raw
// stream when STREAM_RAW=kinesis. Credentials and endpoint come from the default AWS
// config chain - IRSA on AWS, static access-key env vars plus AWS_ENDPOINT_URL on
// Floci (the same mechanism deploy.sh already relies on for the Terraform provider) -
// so this client has no Floci-specific code of its own, matching NewOpenSearch.
type Kinesis struct {
	cl *kinesis.Client
}

func NewKinesis(ctx context.Context, region string) (*Kinesis, error) {
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	if err != nil {
		return nil, err
	}
	return &Kinesis{cl: kinesis.NewFromConfig(cfg)}, nil
}

// PutRecord writes one record keyed by partitionKey (the VIN), so a vehicle's reports
// stay on one shard - the Kinesis equivalent of raw-telemetry's Kafka-key invariant.
func (k *Kinesis) PutRecord(ctx context.Context, stream, partitionKey string, data []byte) error {
	_, err := k.cl.PutRecord(ctx, &kinesis.PutRecordInput{
		StreamName:   aws.String(stream),
		PartitionKey: aws.String(partitionKey),
		Data:         data,
	})
	return err
}

// ListShards returns every shard ID currently open on the stream.
func (k *Kinesis) ListShards(ctx context.Context, stream string) ([]string, error) {
	out, err := k.cl.ListShards(ctx, &kinesis.ListShardsInput{StreamName: aws.String(stream)})
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(out.Shards))
	for _, s := range out.Shards {
		ids = append(ids, aws.ToString(s.ShardId))
	}
	return ids, nil
}

// ShardIterator returns an iterator for the shard: resuming just after
// afterSequenceNumber if it's non-empty (a saved checkpoint), or at TRIM_HORIZON
// otherwise (first run - the shard has never been read before).
func (k *Kinesis) ShardIterator(ctx context.Context, stream, shardID, afterSequenceNumber string) (string, error) {
	in := &kinesis.GetShardIteratorInput{
		StreamName: aws.String(stream),
		ShardId:    aws.String(shardID),
	}
	if afterSequenceNumber != "" {
		in.ShardIteratorType = types.ShardIteratorTypeAfterSequenceNumber
		in.StartingSequenceNumber = aws.String(afterSequenceNumber)
	} else {
		in.ShardIteratorType = types.ShardIteratorTypeTrimHorizon
	}
	out, err := k.cl.GetShardIterator(ctx, in)
	if err != nil {
		return "", err
	}
	return aws.ToString(out.ShardIterator), nil
}

// Record is one Kinesis record, trimmed to what a raw consumer needs.
type Record struct {
	PartitionKey                string
	Data                        []byte
	SequenceNumber              string
	ApproximateArrivalTimestamp time.Time
}

// GetRecords polls the given shard iterator and returns any records found, together
// with the iterator to use on the next poll (empty if the shard has closed for good -
// e.g. after a reshard; not specially handled here, see PLAN.md Phase 7).
func (k *Kinesis) GetRecords(ctx context.Context, shardIterator string, limit int32) ([]Record, string, error) {
	in := &kinesis.GetRecordsInput{ShardIterator: aws.String(shardIterator)}
	if limit > 0 {
		in.Limit = aws.Int32(limit)
	}
	out, err := k.cl.GetRecords(ctx, in)
	if err != nil {
		return nil, "", err
	}
	recs := make([]Record, len(out.Records))
	for i, r := range out.Records {
		recs[i] = Record{
			PartitionKey:   aws.ToString(r.PartitionKey),
			Data:           r.Data,
			SequenceNumber: aws.ToString(r.SequenceNumber),
		}
		if r.ApproximateArrivalTimestamp != nil {
			recs[i].ApproximateArrivalTimestamp = *r.ApproximateArrivalTimestamp
		}
	}
	return recs, aws.ToString(out.NextShardIterator), nil
}
