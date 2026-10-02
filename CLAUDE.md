# CLAUDE.md

Rules for every change in this repository. README.md explains the system; PLAN.md holds the
current work plan and its status. When they disagree with the code, the code is not yet done:
check PLAN.md before "fixing" it back.

## Working with the user

- Don't add, swap or remove architecture components without asking the user first.
- Don't record anything as decided (in code comments, docs or PLAN.md) until the user has
  explicitly chosen it. Proposals are labelled as proposals.
- Follow PLAN.md in order. Before starting a task marked **Needs approval**, ask the user.
  Tick tasks off and write findings under the task as you go.
- Fix build or deploy errors in place; don't restructure to work around them.

## Architecture (specified by the user)

protobuf over MQTT → IoT Core (`fleet/telemetry`) → IoT rule → raw stream (MSK or Kinesis,
picked by `STREAM_RAW`) → telemetry-processor (Redis dedup + VIN→fleet) → `canonical-events` →
realtime-router → gRPC streams opened by dashboard-api → SSE to the React dashboard.
realtime-router also writes to OpenSearch. rbac-authz owns users and permissions.
PostgreSQL holds vehicle↔fleet assignments and grants.

- **Core goal:** an event reaches only dashboard-api pods that have a connected user allowed to
  see that vehicle or fleet, and only those users.
- **IoT Core** is the device entry point on every target.
- **The raw stream is a switch: `STREAM_RAW={msk,kinesis}`, default `msk`.** MSK is the Kafka
  service on every target (Terraform creates `aws_msk_cluster`; Floci emulates it). Kinesis is a
  real `aws_kinesis_stream` on every target too (Floci emulates its data-plane API). Only this
  first hop switches - telemetry-processor's own output (`canonical-events`) always stays on
  MSK/Kafka. Don't mention Floci's internal Kafka broker (Redpanda) except where its behaviour
  differs from MSK.
- **The iot-kafka-bridge Lambda exists on Floci only.** Floci's IoT rule engine runs native rule
  actions but never evaluates IoT SQL substitution templates (confirmed live: `${clientid()}`
  and `${topic()}` both arrive as the literal, unevaluated string), so it can't get the VIN as a
  key without a Lambda decoding the protobuf itself. On AWS, IoT Core writes directly into the
  raw stream with no Lambda: a native `kafka` rule action (behind a VPC destination, SASL/SCRAM
  via the same Secrets Manager secret MSK already uses) when `STREAM_RAW=msk`, or a native
  `kinesis` rule action when `STREAM_RAW=kinesis` - both keyed on `${clientid()}` (the simulator
  sets its MQTT client ID to the VIN).
- The record value is always the **original protobuf bytes, unmodified**; the key is the VIN.
  On the `msk` path, an `ingest_ts` header is set too - by the Lambda on Floci, by the rule's own
  `${timestamp()}` on AWS - telemetry-processor reads it without caring which one set it. The
  `kinesis` path has no header equivalent; telemetry-processor uses the record's own
  `ApproximateArrivalTimestamp` instead. Never convert the payload to JSON before
  telemetry-processor.

## Infrastructure rules

- Every AWS resource is defined in Terraform.
- Exactly **two** scripts: `deploy.sh` creates and starts everything, `destroy.sh` removes
  everything, for every target (AWS and Floci). New targets are switches inside these scripts,
  never new scripts. Makefile targets and build/test tooling are fine.
- Two Terraform stacks, `terraform/infra` then `terraform/platform`, because images are pushed
  to ECR between them. Anything that needs a built image (workloads, the Lambda, the IoT rule
  that invokes it) belongs in the platform stack.
- `deploy.sh` saves deploy-time settings in `deploy.auto.tfvars.json` in each stack;
  `destroy.sh` relies on them. Keep new settings there.
- Floci-specific behaviour is a configuration switch. Shared code must stay acceptable on
  real AWS; don't weaken AWS to suit Floci without the user's approval.

## Design invariants

- **Two permission filters.** dashboard-api sends each router pod the union of its connected
  users' scopes; the router routes on that. dashboard-api re-checks every event per user
  before writing SSE; that second check is authoritative. Scopes refresh every 60 s.
- **dashboard-api streams from every realtime-router pod** (headless Service DNS), because each
  router pod consumes only some partitions.
- **realtime-router has two consumer groups**: live push (starts at log end, drops stale events
  and events for slow subscribers) and OpenSearch persist (commits only after success).
  Indexing must never delay live push.
- **telemetry-processor is at-least-once, never lossy**: produce → set dedup keys → commit
  offsets, in that order.
- **Idempotent storage**: `eventId = VIN-deviceTimestamp` is the OpenSearch `_id`.
- **The raw stream is keyed by VIN** (Kafka key or Kinesis partition key) so a vehicle's reports
  stay in one partition/shard.
- **Auth is an HttpOnly cookie** (`EventSource` can't send headers). `COOKIE_SECURE` stays
  false while the dashboard is served over plain HTTP; set it true once TLS exists.

## Keep in sync

| If you change… | …also change |
|---|---|
| `authz.SimVIN` (`7H4T9K2L5RA%06d`) in `services/internal/authz/store.go` | `format("7H4T9K2L5RA%06d", 102300+i)` in `terraform/platform/simulator.tf` |
| `statusColor` in `web/src/format.ts` | `--s-*` colours in `web/src/styles.css` (Leaflet SVG can't read CSS variables) |
| Any `Env("…")` key read in Go | the matching keys in Terraform (ConfigMap, secrets, Lambda environment) |
| Go module path `github.com/example/fleet-telemetry` | `go_package` in all `.proto` files, `services/Makefile`, the `protoc` step in `services/Dockerfile` |
| ECR repo naming `${project}/${service}` in `terraform/infra/ecr.tf` | image references built by `deploy.sh` |
| `dashboard_allowed_cidrs` | `load_balancer_source_ranges` on the web Service (the in-tree NLB otherwise opens NodePorts to 0.0.0.0/0) |
| The set of services or images | the build loop and ECR checks in `deploy.sh`, the ECR repositories, README |
| A `FROM` line in `services/Dockerfile` or `web/Dockerfile` | the base-image pull list in `deploy.sh`'s Stage 2 (Floci only - pulls each one into the persistent image store once, for offline builds) |

## Conventions

- User-facing messages (API errors, UI text, script output) are plain language and say what
  to do next.
- Go: `log/slog` JSON logs; Prometheus metrics; `/healthz`, `/readyz`, `/metrics` on `:8081`
  for long-running services.
- Dockerfiles build on the builder's native platform and cross-compile to the target platform.
- Dashboard design: dark control rail, light map, one loud element (the live badge),
  Barlow / Barlow Semi Condensed, no generic "AI design" tells, visible keyboard focus,
  `prefers-reduced-motion` respected.

## Before finishing any change

- Go: `make -C services build test` and `go vet ./...` (from `services/`).
- Web: `npm run build` in `web/`.
- Terraform: `terraform fmt -recursive` and `terraform validate` in each stack you touched.
- Scripts: `bash -n deploy.sh destroy.sh` (and shellcheck if available).

## Git Flow

* `main` is the production branch.
* `develop` is the default working branch.
* All feature branches start from `develop`.

For each task/feature:
1. Ask if new feature branch should be created. If yes, create `feat/NNN-brief-feature-name` from `develop`, where `NNN` is the zero-padded sequentially incremented task number.
2. Implement and test the task on that branch.
3. When complete, stage the changes and **draft a commit message in single line format** beginning with the task number (for example, `003: implement Tree-sitter predicates`). **Ask for approval before committing.**
4. After commit approval, commit the changes. **Ask for approval before pushing.**
5. After push, prompt: **"Please create a PR `feat/NNN-...` → `develop` in GitHub, review it, and let me know when it's merged."**
6. After the merge is explicitly confirmed, run:

   ```bash
   git switch develop
   git pull origin develop
   ```
7. Never delete local branches.
**Never commit, push, or switch branches without explicit approval at that step.**