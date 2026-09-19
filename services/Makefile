MODULE := github.com/example/fleet-telemetry
PROTOS := ../proto/telemetry/v1/telemetry.proto ../proto/router/v1/router.proto ../proto/authz/v1/authz.proto

.PHONY: proto deps build test
proto:
	protoc -I ../proto --go_out=. --go_opt=module=$(MODULE) \
	  --go-grpc_out=. --go-grpc_opt=module=$(MODULE) $(PROTOS)

deps: proto
	go mod tidy

build: deps
	go build ./...

test: deps
	go test ./...
