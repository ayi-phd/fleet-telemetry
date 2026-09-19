package platform

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	v4 "github.com/aws/aws-sdk-go-v2/aws/signer/v4"
	"github.com/aws/aws-sdk-go-v2/config"
)

// OpenSearch is a minimal SigV4-signing HTTP client for Amazon OpenSearch Service.
// Credentials come from EKS Pod Identity via the default AWS credential chain.
type OpenSearch struct {
	endpoint string
	region   string
	creds    aws.CredentialsProvider
	signer   *v4.Signer
	http     *http.Client
}

func NewOpenSearch(ctx context.Context, endpoint, region string) (*OpenSearch, error) {
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	if err != nil {
		return nil, err
	}
	if !strings.HasPrefix(endpoint, "http") {
		endpoint = "https://" + endpoint
	}
	return &OpenSearch{
		endpoint: strings.TrimRight(endpoint, "/"),
		region:   region,
		creds:    cfg.Credentials,
		signer:   v4.NewSigner(),
		http:     &http.Client{Timeout: 30 * time.Second},
	}, nil
}

// Do sends a signed request and returns status code and body.
func (o *OpenSearch) Do(ctx context.Context, method, path string, body []byte, contentType string) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, o.endpoint+path, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	if contentType == "" {
		contentType = "application/json"
	}
	req.Header.Set("Content-Type", contentType)
	sum := sha256.Sum256(body)
	creds, err := o.creds.Retrieve(ctx)
	if err != nil {
		return 0, nil, fmt.Errorf("aws credentials: %w", err)
	}
	if err := o.signer.SignHTTP(ctx, creds, req, hex.EncodeToString(sum[:]), "es", o.region, time.Now()); err != nil {
		return 0, nil, err
	}
	resp, err := o.http.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	return resp.StatusCode, b, err
}
