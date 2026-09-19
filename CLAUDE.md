# CLAUDE.md

Context for Claude Code sessions in this repository. Read README.md for the architecture and
user-facing docs; this file covers what the README doesn't: current status, decisions the user
has made since the code was written, invariants that must not break, and the next steps.

## Status: written, never built

The whole repository was written in a sandbox with **no Go, protoc, Terraform, Docker or npm
network access**. Treat every file as unverified:

- No Go code has been compiled. There is no `services/go.sum`; dependencies are resolved by
  `go mod tidy` inside the Docker build.
- The web app has never had `npm install` or a type-check. There is no `package-lock.json`.
- Neither Terraform stack has been through `terraform init`, `validate` or `plan`.
- There are no tests anywhere. `make -C services test` runs, but finds nothing.
- Pinned versions (EKS 1.34, MSK 3.7.x, OpenSearch_2.17, provider and module versions,
  golang:1.25 image) were chosen from memory and may need adjusting.

Expect the first build to surface small errors. Fix them in place; don't restructure.

**The code and README do not yet include the IoT → Lambda → MSK change described below.**
They still use the IoT rule's native Kafka action. Implementing the Lambda is step 2 of the
next steps.

## Hard requirements from the user

- All AWS resources are defined in Terraform.
- Exactly **two** scripts: `deploy.sh` creates and starts everything, `destroy.sh` removes
  everything, for every target (real AWS and Floci). Add targets as a switch inside these two
  scripts, never as new scripts. Makefile targets for building and testing are fine.
- Use **MSK** for Kafka. On Floci, MSK is emulated (Floci happens to back it with a
  Kafka-compatible broker, Redpanda); Terraform still creates `aws_msk_cluster` and nothing
  should refer to Redpanda except where Floci's emulation behaves differently.
- Keep **IoT Core** for device ingestion, on AWS and on Floci.
- The architecture was specified by the user. Current version, including the change approved
  after the initial build:

  protobuf over MQTT → IoT Core (`fleet/telemetry`) → IoT rule → **iot-kafka-bridge Lambda**
  → MSK `raw-telemetry` → telemetry-processor (Redis dedup + VIN→fleet) → `canonical-events`
  → realtime-router → gRPC streams opened by dashboard-api → SSE to React. realtime-router
  also writes to OpenSearch. rbac-authz owns permissions. PostgreSQL holds vehicle↔fleet data.

  Don't swap or add components without asking the user first, and don't record a choice as
  decided until the user has explicitly made it.
- Core goal: an event reaches **only** dashboard-api pods that have a connected user allowed to
  see that vehicle or fleet.

## Decided: Lambda between IoT Core and MSK, on AWS and on Floci

The user chose to route IoT Core → Lambda → MSK on **both** real AWS and Floci, replacing the
IoT rule's native Kafka action, so both environments behave the same. "On real AWS too is fine
for now": the user may revisit this later.

Why it's needed on Floci: Floci's IoT rules have no Kafka action and don't evaluate `${}`
substitution templates, but they can invoke Lambda, and Floci runs Lambda in real containers.

Planned design (nothing built yet):

- **New binary `services/cmd/iot-kafka-bridge`**, a Go Lambda reusing `internal/platform`
  Kafka config (TLS + SASL/SCRAM from env). Create the Kafka client once per execution
  environment, not per invocation.
- **Receive raw bytes.** Implement the `lambda.Handler` interface
  (`Invoke(ctx, []byte) ([]byte, error)`) so the protobuf payload isn't parsed as JSON.
- **Rule SQL `SELECT * FROM 'fleet/telemetry'`.** On Floci this forwards the published bytes
  unchanged; any other projection requires a JSON payload, which protobuf isn't.
- **Kafka key = VIN decoded from the protobuf**, not the MQTT client ID, because Floci can't
  pass `clientid()` without a JSON projection. Per-vehicle partitioning still holds. Headers:
  `ingest_ts` set by the Lambda (receive time, ms). `mqtt_client_id` is not available on Floci.
- **Produce synchronously** and return an error on failure so the invocation is retried.
- **Deploy as a container-image Lambda** built by `deploy.sh` with the other images
  (`services/Dockerfile --build-arg SERVICE=iot-kafka-bridge`, on a Lambda-compatible base
  image). Because the image must exist first, the Lambda **and the IoT topic rule** move from
  the infra stack to the platform stack. Add the ECR repository to `terraform/infra/ecr.tf`.
- **On AWS the Lambda runs in the VPC** (private subnets, a security group allowed to reach
  MSK on 9096). Credentials come from the existing `AmazonMSK_${project}` secret.
- **Remove from Terraform**: the IoT rule's `kafka` action, its VPC rule destination and that
  destination's IAM role, and the rule role's Secrets Manager/KMS permissions. Keep the
  CloudWatch error action. Add `aws_lambda_permission` for `iot.amazonaws.com`.
- **Update README.md** (diagram, "How a position report travels", delivery guarantees).

Consequences to document and accept:

- The Kafka key no longer proves which device sent a message (a device could publish another
  VIN). Acceptable for now; on AWS the IoT policy still restricts each device to its own
  client ID for connecting.
- IoT invokes Lambda asynchronously, and async retries can reorder a vehicle's reports.
  Downstream already tolerates this: telemetry-processor dedups, and the dashboard keeps the
  newest `deviceTimestamp` per VIN. Configure a Lambda on-failure destination or DLQ so
  exhausted retries aren't lost silently.
- `destroy.sh` must tolerate Lambda's VPC network interfaces, which AWS can take 20+ minutes to
  release after the function is deleted. Its retry loop may need longer waits.

To verify when implementing:

- Whether real AWS IoT delivers a non-JSON payload to a Lambda action with `SELECT *`, or
  needs `SELECT encode(*, 'base64') AS payload`. If the latter, the handler should accept both
  raw bytes (Floci) and that JSON envelope (AWS). Floci doesn't support `encode()`.
- Whether Floci's MSK emulation accepts TLS + SASL/SCRAM. If not, the Floci target sets
  `KAFKA_TLS=false` and an empty `KAFKA_USERNAME` (already supported by `platform/kafka.go`).

## Floci (local AWS emulator): chosen local target

The user wants to run the platform on Floci on a MacBook Air (24 GB). Beyond the Lambda
above, Floci differs from AWS in ways the Floci target must handle (plan still to be agreed
with the user):

- **EKS** runs as one k3s container per cluster: no add-ons, no encryption config, node groups
  are metadata only (so the `workload=edge` node selector and taint must be dropped), and Floci
  documents IRSA but not Pod Identity (realtime-router and dashboard-api need AWS credentials
  to sign OpenSearch requests).
- **No NLB**: k3s has no AWS cloud provider. Reach the dashboard with `kubectl port-forward`.
- **EKS auth** needs a real IAM access key created in Floci; `test`/`test` is rejected.
- **Terraform AWS provider** must point at Floci's endpoint (`http://localhost:4566`).
- **Still to verify**: ElastiCache with TLS + auth token, and whether endpoints returned by
  Floci are reachable from inside k3s pods.
- Run services at one replica each; give Docker Desktop about 12 GB.

## Invariants (things that silently break if changed on one side only)

| If you change… | …also change |
|---|---|
| `authz.SimVIN` (`SIM%014d`) in `services/internal/authz/store.go` | `format("SIM%014d", i)` in `terraform/platform/simulator.tf` |
| `statusColor` in `web/src/format.ts` | `--s-*` colours in `web/src/styles.css` (Leaflet SVG can't read CSS variables) |
| Any `Env("…")` key read in Go | the ConfigMap/secret keys in `terraform/platform/main.tf`, `web.tf`, `simulator.tf` (and the Lambda's environment once it exists) |
| Go module path `github.com/example/fleet-telemetry` | `go_package` in all three `.proto` files, `services/Makefile`, the `protoc` step in `services/Dockerfile` |
| ECR repo naming `${project}/${service}` in `terraform/infra/ecr.tf` | image tags built in `deploy.sh` |
| `dashboard_allowed_cidrs` handling | `load_balancer_source_ranges` in `terraform/platform/web.tf` (the in-tree NLB opens NodePorts to 0.0.0.0/0 without it) |
| The Kafka record key for `raw-telemetry` | must stay the VIN, so each vehicle's reports land in one partition |

## Design decisions to preserve

- **Two permission filters.** Each dashboard-api pod sends every router pod the union of its
  connected users' scopes (`InterestUpdate`); the router routes on that. dashboard-api then
  re-checks each event per user before writing SSE. The second check is authoritative. Scopes
  are re-read every 60 s so grant changes reach open streams.
- **dashboard-api connects to every realtime-router pod** via the headless Service DNS, because
  each router pod consumes only some partitions of `canonical-events`.
- **realtime-router uses two consumer groups**: push (starts at log end, drops events older
  than `PUSH_MAX_AGE`, drops on slow subscribers) and persist (OpenSearch bulk, commits only
  after success). Indexing latency must never delay live push.
- **At-least-once, never lossy, in telemetry-processor**: produce canonical events → then set
  dedup keys → then commit offsets. Don't reorder. Downstream is idempotent because
  `eventId = VIN-deviceTimestamp` is the OpenSearch `_id`.
- **`raw-telemetry` is keyed by VIN** so a vehicle's reports stay in one partition. (Today the
  IoT rule keys by `${clientid()}`, which equals the VIN; the Lambda will key by the VIN in
  the payload.)
- **Auth is an HttpOnly cookie**, not a header, because `EventSource` can't set headers.
  `COOKIE_SECURE` defaults to false because the demo NLB is plain HTTP; set it true when TLS
  is added.
- **Two Terraform stacks** because images must be pushed to ECR between creating the cluster
  and deploying workloads. `deploy.sh` writes `deploy.auto.tfvars.json` in each stack so
  `destroy.sh` sees the same region and tag.
- **Dockerfiles cross-compile** (`--platform=$BUILDPLATFORM`), so arm64 Macs build the amd64
  images for EKS without emulation.

## Conventions

- User-facing error messages (HTTP JSON errors, UI text) are plain language and say what to do.
- Dashboard design follows the frontend-design guidance: dark control rail, light map, one
  loud element (the live badge), Barlow / Barlow Semi Condensed, no generic "AI design" tells.
  Keep keyboard focus visible and respect `prefers-reduced-motion`.
- Go: `log/slog` JSON logging, Prometheus metrics, `/healthz` `/readyz` `/metrics` on `:8081`
  (not applicable to the Lambda, which logs to CloudWatch).

## Building

Inside Docker (no local toolchain needed), from the repo root:

```bash
docker buildx build -f services/Dockerfile --build-arg SERVICE=telemetry-processor .
docker buildx build web
```

Natively: Go 1.24+, `protoc`, `protoc-gen-go@v1.34.2`, `protoc-gen-go-grpc@v1.5.1`, then
`make -C services build`. Generated code goes to `services/gen/` (gitignored).

## Next steps, in order

1. **Get everything compiling.**
   - `make -C services build` and `go vet ./...`; fix errors; commit `services/go.sum`.
   - `cd web && npm install && npm run build`; fix type errors; commit `package-lock.json`.
   - `terraform fmt -recursive` and `terraform init -backend=false && terraform validate` in
     both `terraform/infra` and `terraform/platform`; commit `.terraform.lock.hcl` files.
2. **Add the iot-kafka-bridge Lambda** as designed above, on AWS first: Go code, image build in
   `deploy.sh`, Terraform changes, README update. Validate again.
3. **Unit tests**, highest value first:
   - `router.Interest.Matches` and `Hub.Dispatch` (including drop-on-slow-subscriber).
   - `dashboard.Broker`: per-user filtering, `recompute()` union (admin → `all=true`),
     `UpdateScope`; `InterestBus` version increments.
   - `processor`: dedup, fleet lookup, `UNASSIGNED`, invalid → DLQ, and the
     produce → dedup-set → commit ordering. Use franz-go's `kfake` and `miniredis`.
   - iot-kafka-bridge: VIN extraction and keying, raw-bytes and base64-envelope inputs,
     error returned when produce fails.
   - `model.Validate`, JWT issue/parse round-trip.
   - `authz.Store` against real PostgreSQL via testcontainers-go: scopes for each demo user;
     re-seeding preserves admin reassignments.
   - Web: Vitest for the stream merge (newest `deviceTimestamp` per VIN) and `format.ts`.
4. **Floci target.** Agree the plan with the user first (see "Floci" above), then add it as a
   target switch in `deploy.sh` / `destroy.sh` with the Terraform differences it needs.
5. **Deploy to real AWS** with `./deploy.sh`, verify end to end, and `./destroy.sh`.
