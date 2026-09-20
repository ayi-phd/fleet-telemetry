# syntax=docker/dockerfile:1.7
# Build context: repository root. Usage:
#   docker buildx build -f services/Dockerfile --build-arg SERVICE=telemetry-processor .
# The build stage runs on the builder's native platform and cross-compiles, so an
# arm64 laptop produces amd64 images for the EKS nodes without QEMU emulation.
FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS build
ARG SERVICE
ARG TARGETOS=linux
ARG TARGETARCH=amd64
ENV GOTOOLCHAIN=auto CGO_ENABLED=0
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler \
 && rm -rf /var/lib/apt/lists/*
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.34.2 \
 && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1
WORKDIR /src
COPY proto/ proto/
COPY services/ services/
WORKDIR /src/services
RUN protoc -I ../proto \
      --go_out=. --go_opt=module=github.com/example/fleet-telemetry \
      --go-grpc_out=. --go-grpc_opt=module=github.com/example/fleet-telemetry \
      ../proto/telemetry/v1/telemetry.proto ../proto/router/v1/router.proto ../proto/authz/v1/authz.proto
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    go mod download && GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/${SERVICE}

# Long-running Kubernetes services: --target runtime-standard
FROM gcr.io/distroless/static-debian12:nonroot AS runtime-standard
COPY --from=build /out/app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]

# iot-kafka-bridge, invoked by AWS IoT Core (or Floci's emulator): --target runtime-lambda.
# The base image's WORKDIR is /var/task; aws-lambda-go talks to the Lambda Runtime API
# itself, so no separate runtime interface client is needed.
FROM public.ecr.aws/lambda/provided:al2023 AS runtime-lambda
COPY --from=build /out/app ./app
ENTRYPOINT ["./app"]
