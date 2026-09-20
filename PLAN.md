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

## Phase 1: IoT Core → Lambda → MSK (Decided, on AWS and Floci) — **done**

Why: Floci's IoT rules have no Kafka action and don't evaluate `${}` substitution templates,
but can invoke Lambda. The user chose the Lambda on real AWS too, so both targets behave the same.

- [x] **New binary `services/cmd/iot-kafka-bridge`** (Go Lambda):
  - `lambda.Handler` (`Invoke(ctx, []byte) ([]byte, error)`) so the payload arrives as raw bytes.
  - Accepts both input forms: raw protobuf bytes, and a JSON envelope with a base64 `payload`.
  - Decodes a copy of the protobuf only to read the VIN. Produces the **original bytes
    unmodified** as the record value, key = VIN, header `ingest_ts` = receive time (ms).
  - Reuses `platform.KafkaConfigFromEnv()`; one client per execution environment; synchronous
    produce; returns an error on failure so the invocation retries.
  - Credentials still come from `KAFKA_USERNAME`/`KAFKA_PASSWORD`/`KAFKA_TLS` like every other
    service — no target-specific branching needed in Go code. The AWS/Floci split (SCRAM vs.
    plaintext) is a Terraform decision deferred to Phase 2/3, since MSK's auth mode isn't
    target-conditional yet.
  - Unit tests written now (`bridge_test.go`, satisfies the Phase 6 item for this handler): VIN
    extraction and keying, both input forms, value bytes unchanged, produce failure returns an
    error. The success/failure paths use `github.com/twmb/franz-go/pkg/kfake` (in-memory broker)
    rather than mocks, so they exercise the real `kgo` produce path.
- [x] **Image**: `services/Dockerfile` now has two named final stages —
      `runtime-standard` (existing distroless image) and `runtime-lambda`
      (`public.ecr.aws/lambda/provided:al2023`; aws-lambda-go talks to the Runtime API itself,
      no separate runtime interface client needed). `deploy.sh` now builds every service with an
      explicit `--target` (no longer relying on "last stage wins"), added `LAMBDA_SERVICES`
      alongside `SERVICES`, and added `iot-kafka-bridge` to `terraform/infra/ecr.tf` and the
      README binary count.
  - **Deviation from the plan text:** still `linux/amd64` / `x86_64`, matching every other
    service today. arm64 is Phase 2 scope (2.1) and will flip the Lambda's `architectures`
    together with the node groups, not ahead of it.
  - **Unverified on this machine:** Docker isn't running here, so neither runtime-image build
    has actually been built yet. First real verification is the Phase 4 Floci deploy.
- [x] **Terraform (platform stack)**: `aws_lambda_function` (`package_type = "Image"`), execution
      role, `aws_lambda_permission` for `iot.amazonaws.com`, `aws_iot_topic_rule` with
      `SELECT * FROM 'fleet/telemetry'` and a `lambda` action (`terraform/platform/lambda.tf`,
      `iot.tf`). `vpc_config` and the on-failure SQS destination are gated `local.floci ? ... `
      (only on AWS) — this introduces `variable "target"` / `local.floci` into the **platform**
      stack now, since this is the first Floci-conditional resource; the **infra** stack doesn't
      need it yet and doesn't have it (deploy.sh still doesn't set `TARGET`; Phase 3 wires that).
  - **Deviation:** did not add `depends_on = [module.telemetry_processor]`. MSK's
    `auto.create.topics.enable=true` (unchanged until Phase 2.7) already covers topic existence,
    matching how the original rule had no such dependency either.
- [x] **Terraform (infra stack)**: removed `aws_iot_topic_rule_destination.msk`,
      `aws_iam_role.iot_destination` + policy, `aws_security_group.iot_destination`, the rule
      role's Secrets Manager/KMS statements, and `aws_iot_topic_rule.telemetry_to_msk` itself.
      Added `output "private_subnet_ids"` for the platform stack's Lambda VPC config.
      `aws_iot_policy.vehicle` and `data.aws_iot_endpoint.ats` stay in infra (no image needed).
- [x] **`destroy.sh`**: lengthened the infra-destroy retry loop (3 attempts/60s →
      4 attempts/5 min). Also found and fixed a related gap: the Lambda's security group now
      lives in the **platform** stack (it's created there, alongside the function), so *that*
      stack's destroy can itself get stuck on a `DependencyViolation` while the ENI releases —
      wrapped the platform destroy step in the same kind of retry loop before its existing
      "cluster already gone" fallback.
  - **Not verified end to end** (no real Lambda has been created/destroyed yet); the 20+ minute
    Lambda-ENI-release behavior is documented AWS behavior, not something observed here.
- [x] **README**: diagram, "How a position report travels" step 2 rewritten for the Lambda path,
      both accepted trade-offs stated inline, binary count corrected to six, and the "IoT rule
      errors" log-tail comment corrected (Kafka → Lambda invoke failures). The log group's name
      and value (`/aws/iot/<project>/rule-errors`) are unchanged; only the owning stack moved.

## Phase 2: shared changes for both targets (Approved) — **done**

- [x] **2.1 arm64 everywhere.** Node groups: `AL2023_ARM_64_STANDARD`, `t4g.large` core /
      `t4g.medium` edge (`variables.tf` defaults changed from `t3.*`). `deploy.sh`'s shared
      `build()` now passes `--platform linux/arm64` for every image (services, web, and the
      Lambda). Lambda `architectures = ["arm64"]`. Dockerfile's `TARGETARCH` default and header
      comment updated to match (buildx still sets it from `--platform` regardless).
  - **Unverified**: no image has actually been built on this machine (Docker isn't running
    here); first real check is the Phase 4 Floci deploy.
- [x] **2.2 Replaced the EKS module with plain resources** (`terraform/infra/eks.tf`):
      `aws_eks_cluster`, two `aws_eks_node_group`s, a cluster IAM role
      (`AmazonEKSClusterPolicy`) and a node IAM role (`AmazonEKSWorkerNodePolicy`,
      `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`), `access_config` exactly as
      planned. Node labels and the edge `NO_SCHEDULE` taint kept. Node groups are
      `count = local.floci ? 0 : 1` — this is the first Floci-conditional resource in the
      **infra** stack, so `variable "target"` / `local.floci` now exist there too (previously
      only in platform; see Phase 1 notes). `terraform init -upgrade` on infra dropped the
      `tls`/`time`/`cloudinit` providers the module pulled in — confirms they're gone.
- [x] **2.3 No EKS add-ons block.** Simply omitted — EKS bootstraps default self-managed VPC
      CNI, kube-proxy and CoreDNS on cluster/node-group creation with no addon resources needed;
      this also removes the `eks-pod-identity-agent` addon, consistent with 2.5.
- [x] **2.4 No customer-managed KMS key for EKS secrets.** Already true before this phase (the
      original module block never set `cluster_encryption_config`) — confirmed, no code change.
- [x] **2.5 Pod Identity → IRSA** (`terraform/infra/iam_pods.tf`): `aws_iam_openid_connect_provider`
      with the well-known static placeholder thumbprint
      (`9e99a48a9960b14926bb7f3b02e22da2b0ab7280` — AWS no longer validates this for an
      issuer backed by a publicly trusted CA, which EKS's always is); per-service-account trust
      policies (`sts:AssumeRoleWithWebIdentity`, `sub`/`aud` conditions) replacing the Pod
      Identity trust doc; both `aws_eks_pod_identity_association` resources deleted. New infra
      outputs `realtime_router_role_arn` / `dashboard_api_role_arn`; the platform stack's shared
      service module gained `service_account_annotations` (maps to
      `kubernetes_service_account_v1.metadata.annotations`), wired to
      `eks.amazonaws.com/role-arn` for both service accounts.
- [x] **2.6 MSK stays SASL/SCRAM on AWS.** No change made — documented only; IAM auth was the
      option the user did not approve.
- [x] **2.7 No custom MSK configuration.** Removed `aws_msk_configuration` and the cluster's
      `configuration_info` block entirely (`terraform/infra/msk.tf`) rather than keeping it
      AWS-only as an earlier draft of this plan said — the whole point is that Floci's MSK
      emulation is unlikely to implement the configuration API at all, so nothing should depend
      on broker-wide config either target. `platform.EnsureTopics` now takes `retention` and
      `minInsyncReplicas` and sets them as **per-topic** configs via `kadm.CreateTopics`'
      existing (previously unused, `nil`) configs parameter; `TOPIC_RETENTION` (`72h`) and
      `TOPIC_MIN_INSYNC_REPLICAS` (`2`) are new env vars, set in
      `terraform/platform/main.tf`'s `telemetry_processor` module alongside the existing
      `TOPIC_PARTITIONS`/`TOPIC_REPLICATION`.
  - **Carried into Phase 3**: `TOPIC_REPLICATION` is still hard-coded `"3"` for both targets
    (pre-existing, not introduced by this phase) — invalid against Floci's single broker. Phase
    3's "Sizing" row already covers making it `local.floci ? "1" : "3"`; left alone here to keep
    this change scoped to what 2.7 asked for.
- [x] **2.8 Scheduling.** The shared service module's `node_selector` var default is now `{}`,
      and driving it no longer sets the Kubernetes `nodeSelector` field at all — instead it
      builds a single **preferred** `node_affinity` term (one `preference` with a
      `match_expressions` per key, so multi-key semantics match the old hard selector's AND).
      The edge toleration is unchanged. Every caller that relied on the old
      `{ workload = "core" }` default now passes it explicitly (`rbac_authz`,
      `telemetry_processor`, `realtime_router`, `vehicle_simulator`); `dashboard_api` already
      passed `{ workload = "edge" }` explicitly. `web.tf` doesn't use the shared module, so its
      `kubernetes_deployment_v1.web` got the same affinity block hand-written.
- [x] **2.9 Removed the `node_security_group_additional_rules` block** from `eks.tf` — it isn't
      replaced by anything; `loadBalancerSourceRanges` on the web Service already makes the
      in-tree NLB integration open exactly that CIDR range on the node/cluster security group.
      To verify on the Phase 5 AWS deploy, per the original plan.
- [x] **2.10 Simulator CA file.** `cmd/vehicle-simulator`: new `loadCAPool()` reads
      `IOT_CA_FILE` (a PEM bundle) into an `x509.CertPool` used as `tls.Config.RootCAs`; empty
      path falls back to `nil` (system roots), matching today's behavior when unset. Committed
      `terraform/platform/certs/amazon-root-ca-1.pem` (fetched and verified against
      `www.amazontrust.com`, valid until 2038); added as a `"ca.pem"` key in the existing
      `vehicle-certs` secret (already mounted at `/certs`, so no new volume needed);
      `IOT_CA_FILE=/certs/ca.pem` set on the `vehicle_simulator` module.
  - **Known gap, deferred to Phase 3**: the committed file is Amazon's CA on **both** targets
    for now. On Floci this won't verify the emulator's own broker certificate — end-to-end TLS
    only works there once Phase 3's `deploy.sh` fetches Floci's real `/_floci/ca.pem` and this
    secret's `ca.pem` key is swapped to use it instead.
- [x] **2.11 `redis_address` fallback**: `coalesce(primary_endpoint_address,
      configuration_endpoint_address)` in `terraform/infra/outputs.tf`.
- [x] **2.12 OpenSearch index template `number_of_replicas`** is now `Persister.IndexReplicas`
      (`internal/router/persist.go`), read from `OPENSEARCH_INDEX_REPLICAS`
      (`cmd/realtime-router/main.go`, default `1`); the platform stack sets it to
      `local.floci ? "0" : "1"` in the shared config map.
- [x] **README**: cost figures updated for Graviton pricing (~$0.84/h, ~$610/mo; instance types
      `t4g.large`/`t4g.medium`).

Verified after every change in this phase: `make -C services build test`, `go vet ./...`,
`terraform fmt -recursive`, `terraform validate` in both stacks, `npm run build`, `bash -n`.

## Phase 3: the Floci target — **done** (unverified against a live Floci; that's Phase 4)

| Area | Floci | File | Status |
|---|---|---|---|
| VPC | `enable_nat_gateway = !local.floci` | `infra/network.tf` | [x] |
| EKS | cluster only, no node groups | `infra/eks.tf` | [x] already done in Phase 2 |
| MSK | 1 broker, plaintext, unauthenticated, no configuration/SCRAM/KMS | `infra/msk.tf` | [x] |
| ElastiCache | no subnet group, 1 node, no failover/multi-AZ, no TLS or auth token | `infra/datastores.tf` | [x] |
| RDS | `sslmode=disable` in `postgres_dsn` | `infra/outputs.tf` | [x] |
| OpenSearch | 1 instance, no zone awareness, no `vpc_options`, no encryption blocks | `infra/datastores.tf` | [x] |
| IoT | CloudWatch error action gated; `iot_endpoint` overridable by `iot_endpoint_override` | `infra/variables.tf`, `platform/iot.tf` | [x] |
| ECR | registry host derived from a real `repository_url` (now target-agnostic, not just Floci) | `infra/outputs.tf` | [x] |
| Endpoints seen by pods | MSK/Redis/PostgreSQL/OpenSearch addresses rewritten if Floci returns `localhost` | `platform/main.tf` | **deferred to Phase 4** — genuinely unknown without a live Floci; see below |
| Secrets/config | `KAFKA_TLS`/`REDIS_TLS=false`, empty `KAFKA_USERNAME`/password, `TOPIC_REPLICATION`/`TOPIC_MIN_INSYNC_REPLICAS=1` | `platform/main.tf` | [x] |
| Replicas | 1 per service, via `local.replicas` overriding `var.replicas` | `platform/main.tf` | [x] |
| Web exposure | `NodePort`, `wait_for_load_balancer = false`, `dashboard_url` a port-forward hint | `platform/web.tf`, `platform/outputs.tf` | [x] |
| Lambda | no `vpc_config`, no DLQ/event-invoke-config | `platform/lambda.tf` | [x] already done in Phase 1/2 |
| Simulator CA | Floci's real `/_floci/ca.pem`, fetched by `deploy.sh` | `simulator.tf`, `deploy.sh` | [x] |

- [x] **`deploy.sh`**: `TARGET` (`aws`\|`floci`, validated) saved into both stacks'
      `deploy.auto.tfvars.json`.
- [x] **`deploy.sh` on Floci**: checks `$FLOCI_ENDPOINT/_floci/health` and dies with the
      settings needed (network, TLS, IoT endpoint hostname) if unreachable — never starts Floci
      itself. Exports `AWS_ENDPOINT_URL` and `AWS_REGION` (default `us-east-1`, matching
      `floci env`). Creates a Floci-local IAM user (`floci_ensure_deploy_credentials`) and
      caches its access key in `.floci-deploy-key` (gitignored, `chmod 600`) for `aws eks
      get-token`, since Floci accepts `test`/`test` for most calls but rejects it for that one.
      Fetches `/_floci/ca.pem` into `terraform/platform/floci-ca.pem` before the platform apply.
      Skips the NLB wait; the final summary prints `dashboard_url` as-is, which on Floci is
      already a `kubectl port-forward` instruction rather than a URL.
  - **Not done**: the `FLOCI_SERVICES_ECR_URI_STYLE=path` fallback and arch-specific push
    quirks — nothing to write until Phase 4 shows whether the default registry hostname style
    actually works.
- [x] **`destroy.sh`**: reads `target` from the infra state (not from the environment), so
      destroy always matches what deploy created. Verifies Floci reachability and picks up the
      cached deploy credentials the same way. Skips the load-balancer sweep entirely and uses
      a single, fast destroy attempt (no Lambda-ENI or NAT-gateway waits apply). Floci itself is
      never touched.
  - **Found while doing this**: destroy.sh's region-mismatch guard checked for the stale
    `module.eks` state address (dead since Phase 2 replaced the module) — fixed to
    `aws_eks_cluster.this`, and extended with the same guard for a target mismatch.
- [x] **README**: "Running on Floci" section.

**Deferred to Phase 4 (open questions, not implementation gaps):**

- *Endpoints seen by pods.* Whether Floci's MSK/RDS/ElastiCache/OpenSearch endpoints are
  already pod-resolvable, or need rewriting to a Docker-network hostname in `platform/main.tf`,
  cannot be determined without a running Floci. No blind rewriting logic was written; Phase 4's
  fallback table already owns this question.
- The committed `terraform/platform/certs/amazon-root-ca-1.pem` is used as the simulator's
  `ca.pem` on Floci until `floci-ca.pem` exists (Phase 2's noted gap); `deploy.sh` now fetches
  the real one on every Floci run, so this fallback should only ever be visible on a first,
  partial run.
- `terraform validate` passes for both stacks (default `target=aws`). A `terraform plan
  -var target=floci` was also attempted here (no live Floci, dummy credentials): it got past
  generating the plan for every non-AWS-API resource and correctly resolved `target = "floci"`
  and `msk_username = ""` in the output diff, then failed at the AWS provider's own
  `GetCallerIdentity` check — expected without a reachable endpoint, and about as far as this
  can be verified before Phase 4's live run.

## Phase 4: first Floci run

Resolve each open question; apply the fallback where the answer is no, and record the answer.

| Question | Answer |
|---|---|
| Does the Terraform AWS provider honour `AWS_ENDPOINT_URL`? | **Yes.** Confirmed throughout every live run in this phase; no `endpoints {}` block needed. |
| Does Floci return pod-resolvable hostnames for MSK/RDS/ElastiCache/OpenSearch, or does it return `localhost`? | **All four needed a fix, for two different reasons.** OpenSearch (container-name hostname) and MSK (a *different* container-name hostname than the seed address, advertised via Kafka's own metadata protocol - see below) are resolvable in principle, but **nothing on Floci's default Docker bridge network can resolve any container by name at all** (no embedded DNS there - confirmed directly: `nslookup` from inside the k3s node container returns `NXDOMAIN` for a container that demonstrably exists, while reaching the same container by IP works fine). ElastiCache separately returns the literal string `"localhost"` for `primary_endpoint_address`, which is simply wrong at any layer. RDS returns a plain IP and needed no fix. **Fix implemented for all of it**: `deploy.sh` now discovers every `floci-*` container by name at deploy time and patches the resulting IP/name pairs into both the k3s node's `/etc/hosts` (for containerd's image pulls, which resolve at the node level) and CoreDNS's `Corefile` as a `hosts {}` block (for pod-level application traffic, which resolves through cluster DNS) - see Phase 4.5. `redis_address` also got a Floci-specific hostname override in Terraform, matching the pattern already used for `opensearch_endpoint`. |
| Does Floci's `aws_iam_openid_connect_provider` accept the static placeholder thumbprint, and does creating an OIDC provider succeed there at all? | **No.** Floci's EKS emulation never populates `aws_eks_cluster.identity` (permanently empty, confirmed after 30+ minutes of an ACTIVE cluster) — there is no OIDC issuer to create a provider against. IRSA is AWS-only; Floci uses a static Floci-local IAM user's access key instead (Option A, see Phase 3.5 below). |
| Does IoT deliver the protobuf bytes to the Lambda with `SELECT *`? | Still not reached - blocked behind the vehicle-simulator TLS issue below (nothing publishes to `fleet/telemetry` yet to test the rule against). |
| Do plain EKS cluster, IAM roles and `access_config` succeed on Floci? | **Cluster creation succeeds** (reaches `ACTIVE`), with two caveats, both confirmed on live runs and both accepted rather than engineered around (Phase 4.5 below): a transient `FAILED` status during creation that self-resolves, and `access_config` never being echoed back on refresh (forces replacement on every subsequent apply). |
| Does Docker push to the registry host `ecr_registry` now outputs for Floci? | **Yes, once our own bug was fixed** (see Phase 4.5: the doubled-project-name path). With the correct path, push, the k3s node's containerd pull, and `deploy.sh`'s own verification all work reliably. |
| Does Floci's IoT support the CloudWatch error action (already assumed no and gated off)? | Not yet tested; still gated off. |
| Does Floci's MSK accept TLS (already assumed no; plaintext implemented)? | Not yet tested; still plaintext. Kafka itself (topic creation, produce, consume) now works end to end between `telemetry-processor` and `realtime-router` once DNS was fixed. |
| Does Floci's ElastiCache accept an auth token (already assumed no)? | Not yet tested; still no auth token. Confirmed working (`rbac-authz`'s fleet sync, `telemetry-processor`'s dedup) once the hostname fix landed. |
| What scheme/port does Floci's OpenSearch emulation actually serve? | **`http://`, port 9200**, confirmed directly (`docker exec <container> curl http://localhost:9200`) — matches the guess already in place. |

### Phase 4.5: additional findings from live runs, not in the original question list

- [x] **`aws_iam_service_linked_role` (OpenSearch) fails on Floci**: `CreateServiceLinkedRole` returns `UnsupportedOperation`. Fixed: gated to AWS-only in `infra/datastores.tf` (it's only needed for a VPC-attached domain anyway, which is already AWS-only).
- [x] **`aws_db_instance.storage_encrypted` force-replace loop**: Floci doesn't honor/report RDS storage encryption, so declaring `true` there caused an endless false→true diff. Fixed: `storage_encrypted = !local.floci`.
- [x] **OpenSearch domain: two independent, unrelated blockers**, found via a live run:
  1. Floci's `DescribeDomain.Processing` flag never clears (confirmed over 30+ minutes), even though the actual OpenSearch container (a real `opensearchproject/opensearch:2.17.1`) comes up and serves requests within about a minute. Terraform's create waiter can therefore never observe success.
  2. Independently, `hashicorp/terraform-provider-aws` (v5.100.0, and still true on its current unreleased `main` branch — checked) has an unpatched nil-pointer bug: `flattenCognitoOptions` in `internal/service/opensearch/domain.go` dereferences `DescribeDomain`'s `CognitoOptions` field without a nil check. Real AWS always populates it (even when disabled); Floci omits it, and the provider segfaults on any refresh.

  **Fix, discussed and approved with the user**: the native `aws_opensearch_domain` resource is now AWS-only (`count = local.floci ? 0 : 1`). On Floci, a `null_resource` with `local-exec` provisioners (create: `aws opensearch create-domain` + poll the real container via `docker exec ... curl`, since `Processing` can't be trusted; destroy: `aws opensearch delete-domain`) manages it directly instead — invoked automatically by the same `terraform apply`/`destroy` `deploy.sh`/`destroy.sh` already run, so this is not a new script (`CLAUDE.md`: exactly `deploy.sh` and `destroy.sh`). `opensearch_endpoint` is a hardcoded `http://floci-opensearch-<name>:9200` on Floci rather than a computed resource attribute, since there's no native resource to read it from. Unlike EKS/MSK/ElastiCache below, this resource **is** stable across re-deploys (its `triggers` don't change between runs, so Terraform doesn't recreate it every time) — a nicer property than the workaround needed elsewhere.
- [x] **Broader pattern: Floci's `Describe*` responses omit several `ForceNew` fields set at creation**, causing perpetual destroy+recreate on every subsequent apply (not a one-time artifact — confirmed by re-planning a freshly-created, otherwise-untouched stack):
  - EKS: the entire `access_config` block (including `bootstrap_cluster_creator_admin_permissions`).
  - ElastiCache: `engine`.
  - MSK: `broker_node_group_info` and `encryption_info`.

  **Decision (discussed with the user): Option (c), documented and accepted, no code change.** The alternative fixes both have real costs: `lifecycle { ignore_changes = [...] }` can't be written as a `local.floci ? [...] : []` conditional (Terraform requires a literal list for that meta-argument), so applying it would mean either silently ignoring future changes to these attributes on **AWS too** (`CLAUDE.md`: "don't weaken AWS to suit Floci without the user's approval") or duplicating each affected resource block per target. Given these three resources create in seconds to about a minute on Floci once images are cached, the accepted trade-off is:

  **On Floci, every `./deploy.sh` re-run fully destroys and recreates the EKS cluster, the MSK cluster and the ElastiCache replication group.** This means: node groups (if ever added on Floci) would be recreated, all MSK topics and their data are lost, and Redis's dedup/fleet-lookup cache is emptied — every deploy starts fresh. For a throwaway local-dev target this is acceptable; it would not be acceptable on AWS, where none of this occurs (confirmed idempotent there in every run so far).

- [x] **A genuine bug in our own Phase 2 code, not Floci**: the shared service module's
      (and `web.tf`'s) container-level `security_context` block set
      `allow_privilege_escalation`/`read_only_root_filesystem`/`capabilities` but never
      `run_as_non_root`. The Kubernetes provider serializes that as an explicit `false`,
      which *overrides* the pod-level `run_as_non_root = true` (container-level wins),
      violating the namespace's `restricted` Pod Security Standard outright:
      `runAsNonRoot != true (container "X" must not set securityContext.runAsNonRoot=false)`.
      Every pod failed to schedule at all until this was fixed. This would have failed
      identically on real AWS with the same PSA label - Phase 4 is simply the first time
      any of this code actually ran against a real Kubernetes API. Fixed by adding
      `run_as_non_root = true` to the container-level block too, in both places.
- [x] **A second genuine bug in our own Phase 3 code, not Floci**: `ecr_registry`'s
      derivation (`infra/outputs.tf`) stripped only the *last* path segment of a real
      `repository_url`, assuming its shape was `<host>/<reponame>`. It's actually
      `<host>/<project>/<reponame>` (two segments, since `ecr.tf` names repos
      `"${project}/${reponame}"`), so the "fixed" output still had `/<project>` on the
      end. `deploy.sh` then built every image reference as
      `$REGISTRY/$PROJECT/$repo`, appending the project name a *second* time
      (`fleet-telemetry/fleet-telemetry/dashboard-api`). Every push, and `deploy.sh`'s own
      post-push verification, silently used this wrong-but-internally-consistent path for
      the entire session until caught - k3s's containerd, pulling the *correctly*-formed
      path Terraform assembles independently for the Deployment spec, got `NAME_UNKNOWN`.
      This produced a long chain of misleading symptoms (looked exactly like a registry
      control-plane/GC bug) before a live inspection of the registry's own
      `POST /_floci/ecr/gc` dry-run output - which lists every stored repo path - made
      the doubling directly visible. Fixed: `ecr_registry` now takes just the first
      (host) path segment.
- [x] **No embedded DNS between Floci's own containers, at all** (not eviction, not a
      "community edition" limit - both were considered and ruled out: the registry
      container never restarted, has a real persistent volume, and its GC only marks
      objects, never found anything eligible for deletion). Two independent consequences,
      both needing a fix:
  - containerd (image pulls, at the k3s **node** level) resolves via the node's own
    `/etc/resolv.conf`, which points at Docker Desktop's VM resolver - never at Floci's
    containers. Fixed in `deploy.sh`: after `aws eks update-kubeconfig`, discover every
    `floci-*` container's IP and append it to the node container's `/etc/hosts`.
  - Pods resolve via cluster CoreDNS, which does *not* consult the node's `/etc/hosts`.
    k3s's own `NodeHosts` ConfigMap key looked promising (CoreDNS's Corefile already has
    `hosts /etc/coredns/NodeHosts { ... fallthrough }`) but is k3s's live cluster-*node*
    registry, not a copy of `/etc/hosts` - it gets reconciled back to just the node's own
    self-entry, so edits there don't survive. Fixed in `deploy.sh`: patch the *same*
    discovered entries directly into the `hosts` block already inside the Corefile
    (which k3s does not reconcile), then restart CoreDNS to pick it up.
  - Both patches re-run on every `deploy.sh` invocation, since Floci recreates the EKS
    node container (and so its `/etc/hosts` and the fresh CoreDNS ConfigMap) on every
    apply per the accepted Option (c) above.
  - Portability note for whoever touches this next: building the multi-line `hosts{}`
    insertion was tried three ways before landing on one that works on macOS's `sed`/
    `awk` (which this machine uses) - a `sed` substitution with an embedded `\n` in the
    replacement, then `awk -v block="<multi-line>"`, both failed silently or loudly on
    BSD tools that GNU equivalents accept. What works, and is what's in `deploy.sh` now:
    write the new lines to a temp file and use sed's `r` (read-file) command to insert
    them after the matching line - this has no replacement-text parsing at all.
  - This also means Kafka needed *two* different fixes, not one: the seed
    `bootstrap_brokers` address Terraform outputs is a plain, reachable IP, but once
    connected, MSK's broker advertises its *own* container name
    (`floci-msk-<random-suffix>`, not derivable from any Terraform output) in Kafka's
    metadata protocol, and clients reconnect to *that* for actual produce/consume. The
    dynamic `floci-*` discovery above happens to cover this for free, since it patches
    in whatever MSK container actually exists by name, not a hardcoded one.
- [ ] **Still blocking, and not fixable in this repository**: Floci's IoT certificate
      emulation is broken. `aws iot describe-certificate` returns
      `"certificatePem": "-----BEGIN CERTIFICATE-----\n<the certificate's own hex ID>\n-----END CERTIFICATE-----"`
      - the certificate ID wrapped in PEM armor, not a real X.509 certificate - confirmed
      directly against the raw API response, not a parsing issue on our end. Every
      `vehicle-simulator` connection fails immediately with `x509: malformed certificate`
      before any TLS handshake is attempted. There is no code change available in this
      repository that fixes Floci's own certificate generation; a workaround (e.g.
      generating simulator certificates ourselves instead of relying on
      `aws_iot_certificate`, and updating the IoT policy/simulator TLS setup to match)
      would be a real design change requiring the user's decision, not something to pick
      unilaterally. Not yet decided.

**Status at the end of this session**: on a from-scratch Floci deploy, Stage 1 (infra)
and Stage 2 (image build/push) complete cleanly and repeatably. In Stage 3,
**`rbac-authz`, `telemetry-processor`, `realtime-router`, `dashboard-api` and `web` all
reach `1/1 Running`** - the full pipeline from Postgres/Redis/Kafka/OpenSearch through to
the dashboard is up. Only `vehicle-simulator` is blocked, on the IoT certificate issue
above, which also means the IoT→Lambda→MSK leg of the pipeline (the actual telemetry
path) is unverified end-to-end pending that decision.

- [ ] End to end on Floci: simulator → IoT → Lambda → MSK → dashboard, with permission filtering
      working for two users. **Partially reached** — see status above; blocked on the
      simulator TLS/certificate issue.
- [ ] `TARGET=floci ./destroy.sh` removes everything. **Not yet verified** with the
      current, much-more-complete platform stack (DNS patches, `null_resource`
      OpenSearch, IRSA fallback) - worth a full destroy/recreate cycle once the
      simulator question is resolved.

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
