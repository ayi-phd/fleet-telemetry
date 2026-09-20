# PLAN.md: deploy and run on Floci and on real AWS

**Objective:** the platform builds, deploys and runs end to end on Floci and on real AWS, from
the same code, with Floci differences limited to configuration switches in `deploy.sh`,
`destroy.sh` and a Terraform `target` variable.

How to use this plan: work the phases in order. Each task is labelled:

- **Decided**: the user chose it; implement as written.
- **No decision needed**: routine engineering work.
- **Needs approval**: a proposal. Ask the user before starting; record their answer here.

Tick tasks (`[x]`) as they're done and add findings or deviations under the task.

## Decisions taken

- **Order: Floci first**, then one AWS verification run.
- **The AWS run (Phase 5) needs its own explicit human approval.** Approval of this plan is not
  approval to spend money; stop after Phase 4 and ask.
- **Build and compile everything before attempting any deploy.**
- **`deploy.sh` does not start Floci.** It checks Floci is up and correctly configured and
  prints the exact command and settings to fix it if not. Floci is expected to be running.
- **Approved shared changes:** arm64 everywhere; EKS module → plain resources; Pod Identity →
  IRSA (and with it: no EKS add-ons block, no customer-managed KMS key for EKS secrets).
- **Not approved:** MSK IAM authentication. AWS keeps SASL/SCRAM; Floci uses plaintext.
- **Full Phase 6 unit tests are in scope.**

## Corrections to the original plan (found by reading the code)

- **No `OPENSEARCH_URL` rename.** `NewOpenSearch` already accepts a full URL
  (`services/internal/platform/opensearch.go:34`); only Terraform needs to emit
  `http://host:port` on Floci. `OPENSEARCH_ENDPOINT` stays.
- **No new `KAFKA_REPLICATION_FACTOR` key.** `TOPIC_PARTITIONS` / `TOPIC_REPLICATION` already
  exist (`services/cmd/telemetry-processor/main.go:42`). What is missing is topic *configs*:
  `EnsureTopics` passes `nil` (`services/internal/platform/kafka.go:50`), so dropping the MSK
  configuration would silently lose `retention.ms` and `min.insync.replicas`.
- **Softer placement is needed for every service, not just dashboard-api.** The service module
  defaults to `node_selector = { workload = "core" }`
  (`terraform/platform/modules/service/main.tf:46`) and `web.tf:19` pins the same. Floci's
  single k3s node has no `workload` label, so *all* pods would be unschedulable.
- **`terraform/platform/outputs.tf:2`** indexes `status[0].load_balancer[0].ingress[0]`; with
  no NLB on Floci that fails during apply, not just when printing.
- **`terraform/infra/outputs.tf:18`** hard-codes `<account>.dkr.ecr.<region>.amazonaws.com`.
  On Floci the registry host must come from `aws_ecr_repository.repository_url`.
- **`postgres_dsn` forces `sslmode=require`** (`terraform/infra/outputs.tf:48`); Floci's
  PostgreSQL has no TLS.
- **The OpenSearch index template sets `number_of_replicas: 1`**
  (`services/internal/router/persist.go`), leaving every index yellow on single-node Floci.

## Design: one `target` switch

`variable "target" { type = string, default = "aws" }` in **both** stacks, with
`locals { floci = var.target == "floci" }`. `deploy.sh` writes it into each stack's
`deploy.auto.tfvars.json`; `destroy.sh` reads it back. Invocation is `TARGET=floci ./deploy.sh`.

Provider targeting relies on `AWS_ENDPOINT_URL` (AWS provider v5.31+), exported by `deploy.sh`;
a `dynamic "endpoints"` block in the provider is the fallback if that proves unreliable.

---

## Phase 0: build and validate what exists (No decision needed) — **done**

- [x] `make -C services build test`, `go vet ./...`; commit `services/go.sum`.
  - Everything compiled with **no source changes**. `go vet` clean. No test files yet (Phase 6).
  - `go mod tidy` pins **`go 1.26.0`**: franz-go v1.22.0 and `golang.org/x/{crypto,sync,sys,text}`
    all require 1.26. So the Dockerfile base moved `golang:1.25-bookworm` → `golang:1.26-bookworm`.
  - Now that `go.sum` is committed, the Docker build runs `go mod download`, not `go mod tidy`
    (reproducible, and it no longer rewrites `go.mod` mid-build).
  - `gofmt` fixed `internal/dashboard/api.go` and `internal/platform/redis.go`.
  - `make proto` needs `protoc` on PATH; it is not installed on this machine. Used protoc 36.2
    with protoc-gen-go v1.34.2 / protoc-gen-go-grpc v1.5.1 (the versions the Dockerfile pins).
    `brew install protobuf` if you want `make` to work directly.
- [x] `cd web && npm install && npm run build`; commit `package-lock.json`.
  - Clean: no type errors, 41 modules, 303 kB bundle. 70 packages.
- [x] `terraform fmt -recursive`; `terraform init -backend=false && terraform validate` in both
      stacks; commit both `.terraform.lock.hcl`.
  - `fmt` fixed `terraform/platform/modules/service/main.tf`. Both stacks validate.
- [x] Check pinned versions exist.
  - Resolve today: `hashicorp/aws ~> 5.95` → 5.100.0; `hashicorp/kubernetes ~> 2.35` → 2.38.0;
    `terraform-aws-modules/vpc ~> 5.21` → 5.21.0 (the 5.x line ends there; 6.x is current);
    `node:22-alpine`, `nginxinc/nginx-unprivileged:1.27-alpine`, `golang:1.26-bookworm` all exist.
  - **Still unverified** (needs a live API): EKS `1.34`, MSK `3.7.x`, `OpenSearch_2.17`. Check
    on the first Floci and AWS applies.
  - The EKS module pin (`~> 20.31`) is moot: Phase 2 removes the module.
- [x] `bash -n deploy.sh destroy.sh` — OK. `shellcheck` is not installed; not run.

## Phase 1: IoT Core → Lambda → MSK (Decided, on AWS and Floci)

Why: Floci's IoT rules have no Kafka action and don't evaluate `${}` substitution templates,
but can invoke Lambda. The user chose the Lambda on real AWS too, so both targets behave the same.

- [ ] **New binary `services/cmd/iot-kafka-bridge`** (Go Lambda):
  - `lambda.Handler` (`Invoke(ctx, []byte) ([]byte, error)`) so the payload arrives as raw bytes.
  - Accept both input forms: raw protobuf bytes, and a JSON envelope with a base64 payload.
  - Decode a copy of the protobuf only to read the VIN. Produce the **original bytes unmodified**
    as the record value, key = VIN, header `ingest_ts` = receive time (ms).
  - Reuse `internal/platform` Kafka config; create the client once per execution environment.
    Produce synchronously; return an error on failure so the invocation retries.
  - SCRAM credentials from the Lambda environment on AWS; plaintext on Floci.
- [ ] **Image**: `services/Dockerfile --build-arg SERVICE=iot-kafka-bridge` on a Lambda-compatible
      base (`public.ecr.aws/lambda/provided:al2023`, arm64); add to the `deploy.sh` build loop and
      ECR checks, `terraform/infra/ecr.tf`, and the README service list.
- [ ] **Terraform (platform stack)**: container-image `aws_lambda_function`,
      `architectures = ["arm64"]`; `vpc_config` **only on AWS**; execution role;
      `aws_lambda_permission` for `iot.amazonaws.com`; on-failure destination or DLQ on AWS;
      move `aws_iot_topic_rule` here with `SELECT * FROM 'fleet/telemetry'` and a Lambda action.
      Deploy after telemetry-processor so `raw-telemetry` exists.
- [ ] **Terraform (infra stack)**: remove `aws_iot_topic_rule_destination.msk`,
      `aws_iam_role.iot_destination` + policy, `aws_security_group.iot_destination`, and the rule
      role's Secrets Manager/KMS statements.
- [ ] **`destroy.sh`**: Lambda VPC network interfaces can take 20+ minutes to release; lengthen
      the infra-destroy retry loop.
- [ ] **README**: diagram, "How a position report travels", delivery guarantees, and these
      accepted trade-offs:
  - The Kafka key no longer proves which device sent a message. On AWS the IoT policy still
    binds each connection to its own thing.
  - Async invocation retries can reorder a vehicle's reports; telemetry-processor dedups and the
    dashboard keeps the newest `deviceTimestamp` per VIN.

## Phase 2: shared changes for both targets (Approved)

- [ ] **2.1 arm64 everywhere.** Node groups on Graviton (`AL2023_ARM_64_STANDARD`, t4g.large core,
      t4g.medium edge); `deploy.sh` builds `linux/arm64`; Lambda `architectures = ["arm64"]`.
- [ ] **2.2 Replace the EKS module with plain resources**: `aws_eks_cluster`, `aws_eks_node_group`,
      cluster and node IAM roles, `access_config { authentication_mode = "API_AND_CONFIG_MAP",
      bootstrap_cluster_creator_admin_permissions = true }`. Keep node labels and the edge taint.
      Node groups are skipped on Floci.
- [ ] **2.3 No EKS add-ons block.** Rely on the default VPC CNI, kube-proxy and CoreDNS.
- [ ] **2.4 No customer-managed KMS key for EKS secrets.**
- [ ] **2.5 Pod Identity → IRSA.** `aws_iam_openid_connect_provider` with a static thumbprint (no
      certificate fetch); `eks.amazonaws.com/role-arn` annotations on the `realtime-router` and
      `dashboard-api` service accounts; delete both `aws_eks_pod_identity_association` resources
      and swap the trust policy in `terraform/infra/iam_pods.tf`.
- [ ] **2.6 MSK keeps SASL/SCRAM on AWS** (not IAM). Floci gets `unauthenticated = true`,
      `client_broker = "PLAINTEXT"`, one broker, and no SCRAM secret / KMS key / association.
- [ ] **2.7 No custom MSK configuration.** `aws_msk_configuration` becomes AWS-only, and
      `platform.EnsureTopics` gains a configs map (`retention.ms`, `min.insync.replicas`) so topic
      settings live in code. Nothing may rely on topic auto-creation.
- [ ] **2.8 Scheduling.** The service module's `node_selector` default becomes `{}`; core/edge
      placement moves to **preferred** node affinity plus the existing edge toleration, for the Go
      services and the `web` Deployment.
- [ ] **2.9 Remove the explicit NodePort security group rule**; `loadBalancerSourceRanges` on the
      web Service already drives it. Verify on the Phase 5 AWS deploy.
- [ ] **2.10 Simulator trusts a CA file** (`IOT_CA_FILE`, mounted from a secret): Amazon Root CA 1
      on AWS (public, commit it), Floci's `/_floci/ca.pem` on Floci (fetched by `deploy.sh`).
      Today it uses system roots, which don't include Floci's CA.
- [ ] **2.11 `redis_address` output** becomes `coalesce(primary_endpoint_address,
      configuration_endpoint_address)`. Floci fills only the configuration endpoint for
      cluster-mode-disabled replication groups.
- [ ] **2.12 OpenSearch index template `number_of_replicas`** becomes a setting (0 on Floci).
- [ ] Update README for these (cost, prerequisites, security).

## Phase 3: the Floci target

| Area | Floci | File |
|---|---|---|
| VPC | `enable_nat_gateway = false` (`CreateNatGateway` unsupported) | `infra/network.tf` |
| EKS | cluster only, no node groups | `infra/eks.tf` |
| MSK | 1 broker, plaintext, unauthenticated, no configuration/SCRAM/KMS | `infra/msk.tf` |
| ElastiCache | no subnet group (`CreateCacheSubnetGroup` unsupported), 1 node, no failover/multi-AZ, no TLS or auth token | `infra/datastores.tf` |
| RDS | `sslmode=disable` in `postgres_dsn` | `infra/outputs.tf` |
| OpenSearch | 1 instance, no zone awareness, no `vpc_options`, no encryption blocks | `infra/datastores.tf` |
| IoT | no VPC destination; CloudWatch error action gated; `iot_endpoint` overridable by variable | `infra/iot.tf` |
| ECR | registry host from `aws_ecr_repository.repository_url` | `infra/outputs.tf` |
| Endpoints seen by pods | MSK/Redis/PostgreSQL/OpenSearch addresses rewritten to a hostname pods can resolve when Floci returns `localhost` | `platform/main.tf` |
| Secrets/config | `KAFKA_TLS=false`, empty `KAFKA_USERNAME`, `REDIS_TLS=false`, no Redis password, `TOPIC_REPLICATION=1` | `platform/main.tf` |
| Replicas | 1 per service | `platform/variables.tf` |
| Web exposure | `NodePort`, `wait_for_load_balancer = false`, `dashboard_url` guarded | `platform/web.tf`, `platform/outputs.tf` |
| Lambda | no `vpc_config` | `platform/lambda.tf` |

- [ ] `deploy.sh`: `TARGET` (default `aws`) saved into both `deploy.auto.tfvars.json`.
- [ ] `deploy.sh` on Floci: verify Floci is reachable (`/_floci/health`) and configured — k3s and
      Floci on one Docker network (`FLOCI_SERVICES_DOCKER_NETWORK` /
      `FLOCI_SERVICES_EKS_DOCKER_NETWORK`), `FLOCI_TLS_ENABLED=true`,
      `FLOCI_SERVICES_IOT_ENDPOINT_ADDRESS` set to a pod-resolvable hostname. If not, fail with
      the exact command and settings to use.
- [ ] `deploy.sh` on Floci: export `AWS_ENDPOINT_URL` and credentials; create an IAM user and
      access key for EKS auth (`test`/`test` is rejected); fetch `/_floci/ca.pem`; build
      `linux/arm64`; push to the Floci ECR registry (default `hostname` URI style, fallback
      `FLOCI_SERVICES_ECR_URI_STYLE=path`); skip the NLB wait and print a `kubectl port-forward`
      command instead of a URL.
- [ ] `destroy.sh`: read the saved target; gate the AWS-only sweeps
      (`resourcegroupstaggingapi`, `elbv2`, ENI and `k8s-*` security-group cleanup, kubeconfig
      removal) behind `target == aws`; leave the Floci container running.
- [ ] README: "Running on Floci" section.

## Phase 4: first Floci run

Resolve each open question; apply the fallback where the answer is no, and record the answer.

| Question | Fallback |
|---|---|
| Does the Terraform AWS provider honour `AWS_ENDPOINT_URL`? | `dynamic "endpoints"` block on the Floci target |
| Does Floci return pod-resolvable hostnames for MSK/RDS/ElastiCache/OpenSearch? | Override the addresses in the platform stack |
| Does `aws_iam_openid_connect_provider` accept no thumbprint? | Static thumbprint |
| Does IoT deliver the protobuf bytes to the Lambda with `SELECT *`? | Rule SQL variant on Floci; the handler already accepts both forms |
| Do plain EKS cluster, IAM roles and `access_config` succeed on Floci? | Already skipping node groups; fall back further if needed |
| Does Docker push to `*.dkr.ecr.<region>.localhost:4566`? | `FLOCI_SERVICES_ECR_URI_STYLE=path` |
| Does Floci's IoT support the CloudWatch error action? | Drop it on Floci |
| Do Floci's MSK and Valkey accept TLS? | Plaintext on Floci |

- [ ] End to end on Floci: simulator → IoT → Lambda → MSK → dashboard, with permission filtering
      working for two users.
- [ ] `TARGET=floci ./destroy.sh` removes everything.

## Phase 5: verify on real AWS — **gated, needs separate human approval**

Costs roughly $0.90/hour. Do not start without asking at that point.

- [ ] `./deploy.sh`; confirm all pods ready and the dashboard reachable.
- [ ] Simulator → IoT → Lambda → MSK → processor → router → dashboard works; the IoT rule error
      log and the Lambda's failure destination are empty.
- [ ] Record whether IoT delivered raw bytes with `SELECT *` or the rule needs
      `encode(*, 'base64')`; adjust the rule SQL if needed.
- [ ] Permission filtering: two users in separate browsers see only their vehicles.
- [ ] 2.9 check: the node security group has the client-range rules.
- [ ] Confirm the pinned EKS, MSK and OpenSearch versions are accepted.
- [ ] `./destroy.sh`; confirm nothing is left (ELBs, ENIs, Lambda ENIs, IoT things/certs).

## Phase 6: unit tests

- [ ] `iot-kafka-bridge`: VIN extraction and keying, both input forms, value bytes unchanged,
      error returned when produce fails.
- [ ] `router.Interest.Matches`, `Hub.Dispatch` (including drop-on-slow-subscriber).
- [ ] `dashboard.Broker` per-user filtering, `recompute()` union (admin → `all=true`),
      `UpdateScope`; `InterestBus` version increments.
- [ ] `processor`: dedup, fleet lookup, `UNASSIGNED`, invalid → DLQ, produce → dedup-set → commit
      ordering (franz-go `kfake`, `miniredis`).
- [ ] `model.Validate`; JWT issue/parse round-trip.
- [ ] `authz.Store` against PostgreSQL via testcontainers-go: scopes per demo user; re-seeding
      keeps admin reassignments.
- [ ] Web (Vitest): stream merge keeps newest `deviceTimestamp` per VIN; `format.ts` helpers.

---

## Reference: AWS trade-offs of this plan

Gains: ~20% cheaper compute (Graviton); no MSK/EKS customer-managed KMS key for EKS secrets; no
custom MSK configuration; topic settings explicit in code; stricter simulator TLS trust.

Costs: hand-written EKS Terraform instead of the module; self-managed EKS networking/DNS
components; no customer-controlled key for EKS secret encryption; dashboard-api may run on a core
node under pressure; the Lambda trade-offs in Phase 1.
