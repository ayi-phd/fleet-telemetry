# PLAN.md: unblock deploys to real AWS and Floci

**Objective:** the platform builds, deploys and runs end to end on real AWS and on Floci
(local AWS emulator on a MacBook Air, 24 GB), from the same code, with Floci differences
limited to configuration switches in `deploy.sh`, `destroy.sh` and Terraform variables.

How to use this plan: work the phases in order. Each task is labelled:

- **Decided**: the user chose it; implement as written.
- **No decision needed**: routine engineering work.
- **Needs approval**: a proposal. Ask the user before starting; record their answer here.

Tick tasks (`[x]`) as they're done and add findings or deviations under the task.

## Current state

The repository was written in a sandbox with no Go, protoc, Terraform, Docker or npm access.

- No Go code has been compiled; there is no `services/go.sum` (resolved by `go mod tidy`
  inside the Docker build).
- The web app has never been installed or type-checked; there is no `package-lock.json`.
- Neither Terraform stack has been through `init`, `validate` or `plan`; no lock files.
- There are no tests.
- Pinned versions (EKS 1.34, MSK 3.7.x, OpenSearch_2.17, provider and module versions,
  golang:1.25 image) were chosen from memory.
- The code still uses the IoT rule's **native Kafka action**, MSK **SCRAM** login, EKS **Pod
  Identity**, the **terraform-aws-modules/eks** module and **amd64** images. Phases 1–2 change
  these.
- No Floci target exists yet.

---

## Phase 0: build and validate what exists (No decision needed)

- [ ] `make -C services build` and `go vet ./...`; fix errors in place; commit `services/go.sum`.
- [ ] `cd web && npm install && npm run build`; fix type errors; commit `package-lock.json`.
- [ ] `terraform fmt -recursive`; `terraform init -backend=false && terraform validate` in
      `terraform/infra` and `terraform/platform`; commit both `.terraform.lock.hcl` files.
- [ ] Check pinned versions exist (EKS version, MSK Kafka version, OpenSearch engine version,
      provider/module versions, base images); adjust to the latest available where needed.
- [ ] `bash -n deploy.sh destroy.sh`, and shellcheck if available.

## Phase 1: IoT Core → Lambda → MSK (Decided, on AWS and Floci)

Why: Floci's IoT rules have no Kafka action and don't evaluate `${}` substitution templates,
but can invoke Lambda (run in real containers). The user chose the Lambda on real AWS too,
"for now", so both targets behave the same.

- [ ] **New binary `services/cmd/iot-kafka-bridge`** (Go Lambda):
  - Implement `lambda.Handler` (`Invoke(ctx, []byte) ([]byte, error)`) so the payload arrives
    as raw bytes, not parsed as JSON.
  - Accept both input forms: raw protobuf bytes, and a JSON envelope with base64 payload
    (in case real AWS needs `SELECT encode(*, 'base64') AS payload`; see Phase 4).
  - Decode a copy of the protobuf only to read the VIN. Produce the **original bytes
    unmodified** as the record value, key = VIN, header `ingest_ts` = receive time (ms).
  - Reuse `internal/platform` Kafka config; create the Kafka client once per execution
    environment. Produce synchronously; return an error on failure so the invocation retries.
  - Kafka login: SCRAM from env/secret as today, or IAM if task 2.6 is approved.
- [ ] **Image**: build via `services/Dockerfile --build-arg SERVICE=iot-kafka-bridge` on a
      Lambda-compatible base image; add it to the `deploy.sh` build loop and ECR checks; add
      the ECR repository in `terraform/infra/ecr.tf`.
- [ ] **Terraform (platform stack)**: container-image `aws_lambda_function` in private subnets
      with a security group allowed to reach MSK; execution role (VPC access, logs, Kafka
      access); `aws_lambda_permission` for `iot.amazonaws.com`; on-failure destination or DLQ
      so exhausted async retries aren't lost; move `aws_iot_topic_rule` here with SQL
      `SELECT * FROM 'fleet/telemetry'`, a Lambda action and the existing CloudWatch error
      action. Deploy after telemetry-processor so `raw-telemetry` exists.
- [ ] **Terraform (infra stack)**: remove the rule's Kafka action, the VPC topic rule
      destination and its IAM role, and the rule role's Secrets Manager/KMS permissions.
- [ ] **`destroy.sh`**: Lambda VPC network interfaces can take 20+ minutes to release after
      deletion; lengthen or extend the infra-destroy retry loop accordingly.
- [ ] **README**: diagram, "How a position report travels", delivery guarantees, and these
      accepted trade-offs:
  - The Kafka key no longer proves which device sent a message (a device could publish
    another VIN). On AWS the IoT policy still binds each connection to its own thing.
  - Async invocation retries can reorder a vehicle's reports; telemetry-processor dedups and
    the dashboard keeps the newest `deviceTimestamp` per VIN.
- [ ] Unit tests for the handler: VIN extraction and keying, both input forms, value bytes
      unchanged, error returned when produce fails.

## Phase 2: shared changes for both targets (Needs approval)

Each is required or strongly helpful for Floci and was judged acceptable on AWS. Ask the user
to approve each (in particular 2.1, 2.2, 2.6, 2.8) before implementing.

- [ ] **2.1 arm64 everywhere.** Node groups on Graviton (`AL2023_ARM_64_STANDARD`, e.g.
      t4g.large core, t4g.medium edge); `deploy.sh` builds `linux/arm64`; Lambda
      `architectures = ["arm64"]`.
      Floci: k3s and Lambda containers on Apple Silicon are arm64. AWS: ~20% cheaper compute.
- [ ] **2.2 Replace the EKS module with plain resources**: `aws_eks_cluster`,
      `aws_eks_node_group`, cluster and node IAM roles (EKS cluster policy; worker node, CNI
      and ECR read-only policies). Deployer admin via
      `access_config { authentication_mode = "API_AND_CONFIG_MAP", bootstrap_cluster_creator_admin_permissions = true }`.
      Keep node labels and the edge taint.
      Floci: the module fetches a TLS certificate from the OIDC issuer (not served by Floci)
      and uses access-policy association (not implemented). AWS: same behaviour, more
      Terraform to maintain.
- [ ] **2.3 No EKS add-ons block.** Rely on the default self-managed VPC CNI, kube-proxy and
      CoreDNS. Floci: add-on APIs not implemented. AWS: those are upgraded manually.
- [ ] **2.4 No customer-managed KMS key for EKS secrets.** EKS envelope-encrypts Kubernetes API
      data by default with an AWS-owned key. Floci: encryption config not implemented.
- [ ] **2.5 Pod Identity → IRSA.** `aws_iam_openid_connect_provider` for the cluster issuer,
      without a certificate fetch (no thumbprint, or a static one if the provider requires
      it); service-account role annotations instead of Pod Identity associations. Roles for
      every AWS-calling pod: telemetry-processor and realtime-router (MSK IAM, if 2.6),
      realtime-router and dashboard-api (OpenSearch). Floci documents IRSA, not Pod Identity.
- [ ] **2.6 MSK login: SCRAM → IAM authentication** (port 9098) using franz-go's AWS SASL
      mechanism with credentials from IRSA (pods) or the execution role (Lambda); IAM
      policies for the needed `kafka-cluster:*` actions (connect, topics, data, groups).
      Removes the `AmazonMSK_*` secret, its KMS key and the SCRAM association. Floci: SCRAM
      association is likely outside its 8 MSK operations. Keep plaintext (`KAFKA_TLS=false`,
      empty `KAFKA_USERNAME`) as the Floci fallback.
- [ ] **2.7 No custom MSK configuration.** Services create topics with explicit partitions,
      `retention.ms` (72 h), `min.insync.replicas` and a new `KAFKA_REPLICATION_FACTOR`
      setting (3 on AWS, 1 on Floci's single broker). Nothing may rely on topic
      auto-creation. Floci: configuration API likely unsupported.
- [ ] **2.8 dashboard-api placement**: hard `workload=edge` node selector → preferred node
      affinity, keeping the toleration. Floci: its single k3s node has no edge label.
      AWS: still on edge nodes normally; may land on a core node under pressure.
- [ ] **2.9 Remove the explicit NodePort security group rule**; the web Service's
      `loadBalancerSourceRanges` already makes Kubernetes open exactly the allowed ranges.
      Verify on the Phase 3 AWS deploy that the rules appear on the nodes' security group.
- [ ] **2.10 OpenSearch address as a full URL** (`OPENSEARCH_URL`: scheme, host, port) instead
      of a bare host; keep SigV4 signing. AWS `https://vpc-…`, Floci `http://…:<port>`.
- [ ] **2.11 Simulator trusts a CA file** (`IOT_CA_FILE`, mounted from a secret): Amazon Root
      CA 1 on AWS (public, commit it), Floci's `/_floci/ca.pem` on Floci (fetched by
      `deploy.sh`). Today it uses system roots, which don't include Floci's CA.
- [ ] **2.12 Redis address fallback**: `coalesce(primary_endpoint_address,
      configuration_endpoint_address)` in the `redis_address` output. Floci fills only the
      configuration endpoint for cluster-mode-disabled replication groups (floci-io/floci
      issues #2618, #2769), so today's output would be `:6379`.
- [ ] Update README for whichever of these are implemented (cost, prerequisites, security).

## Phase 3: verify on real AWS (No decision needed; costs money, confirm timing with the user)

- [ ] `./deploy.sh`; confirm all pods ready and the dashboard reachable.
- [ ] Simulator → IoT → Lambda → MSK → processor → router → dashboard works; check the IoT
      rule error log and the Lambda's failure destination are empty.
- [ ] Record whether IoT delivered raw bytes to the Lambda with `SELECT *` or the rule needs
      `encode(*, 'base64')`; adjust the rule SQL if needed.
- [ ] Permission filtering: two users in separate browsers see only their vehicles.
- [ ] 2.9 check: node security group has the client-range rules.
- [ ] `./destroy.sh`; confirm nothing is left (ELBs, ENIs, Lambda ENIs, IoT things/certs).

## Phase 4: Floci target (Needs approval of the approach; details below are the proposal)

Mechanism: a `target` variable (`aws` | `floci`) in both stacks, written by `deploy.sh` into
`deploy.auto.tfvars.json`; `TARGET=floci ./deploy.sh`; `destroy.sh` reads the saved target.
Default `aws`.

- [ ] **Decide with the user**: should `deploy.sh` start Floci itself with the required
      settings, or expect an already running, correctly configured Floci?
- [ ] **Floci configuration** (documented and/or applied by `deploy.sh`): k3s and Floci on the
      same Docker network (`FLOCI_SERVICES_DOCKER_NETWORK`, or
      `FLOCI_SERVICES_EKS_DOCKER_NETWORK`); `FLOCI_TLS_ENABLED=true` (IoT TLS on 8883);
      `FLOCI_SERVICES_IOT_ENDPOINT_ADDRESS` set to a hostname pods can reach (the Floci
      container name, e.g. `floci`); Docker Desktop memory about 12 GB.
- [ ] **Provider and CLI**: point Terraform and the AWS CLI at Floci
      (`AWS_ENDPOINT_URL=http://localhost:4566`).
- [ ] **Credentials**: `deploy.sh` creates an IAM user and access key in Floci for EKS login
      (`test`/`test` is rejected for EKS auth).
- [ ] **VPC**: NAT gateways off on Floci (`CreateNatGateway` returns UnsupportedOperation).
- [ ] **ElastiCache**: no `aws_elasticache_subnet_group` on Floci (`CreateCacheSubnetGroup`
      unsupported); AWS keeps it.
- [ ] **Service endpoints seen by pods**: pods reach Floci by container name (`http://floci:4566`),
      not `localhost`. The MSK, RDS, ElastiCache and OpenSearch addresses passed to pods must
      use a hostname pods can resolve: use a Floci advertised-hostname setting if one exists,
      otherwise override the addresses in the platform stack on the Floci target.
- [ ] **ECR**: default `hostname` URI style (`000000000000.dkr.ecr.<region>.localhost:<port>`);
      fallback `FLOCI_SERVICES_ECR_URI_STYLE=path`. k3s pulls through the `registries.yaml`
      mirror Floci writes.
- [ ] **Dashboard access**: no NLB on k3s; `deploy.sh` prints a `kubectl port-forward`
      command instead of a URL.
- [ ] **Kafka/Redis security**: TLS and login if Floci supports them, otherwise
      `KAFKA_TLS=false` + no SASL, `REDIS_TLS=false` + no password, on Floci only.
- [ ] **Sizing**: one replica per service; `KAFKA_REPLICATION_FACTOR=1`.
- [ ] **OpenSearch**: `OPENSEARCH_URL` from Floci's domain endpoint (2.10).
- [ ] **Simulator CA**: Floci's `/_floci/ca.pem` (2.11).
- [ ] README: "Running on Floci" section.

## Phase 5: first Floci run (No decision needed)

Resolve each open question; apply the fallback where the answer is no, and record the answer.

| Question | Fallback |
|---|---|
| Does Floci have a setting for the hostname in the endpoints it returns? | Override MSK/RDS/ElastiCache/OpenSearch addresses on the Floci target |
| Does Floci's MSK accept IAM authentication (if 2.6)? | Plaintext Kafka on Floci |
| Do Floci's MSK and Valkey accept TLS? | Plaintext on Floci |
| Does the Terraform AWS provider honour `AWS_ENDPOINT_URL`? | Explicit provider `endpoints {}` block on the Floci target |
| Does the OIDC provider resource accept no thumbprint? | Static thumbprint |
| Does IoT deliver the protobuf bytes to the Lambda with `SELECT *`? | Rule SQL variant on Floci; handler already accepts both forms |
| Do plain EKS node groups, IAM roles and `access_config` succeed on Floci? | Skip node groups on Floci (k3s runs pods on its single node) |
| Does Docker Desktop push to `*.dkr.ecr.<region>.localhost:4566`? | `FLOCI_SERVICES_ECR_URI_STYLE=path` |

- [ ] End to end on Floci: simulator → IoT → Lambda → MSK → dashboard, with permission
      filtering working for two users.
- [ ] `TARGET=floci ./destroy.sh` removes everything.

## Phase 6: unit tests (Needs approval; not required to unblock deploys)

Proposed earlier, not yet requested by the user. Highest value first:

- [ ] `router.Interest.Matches`, `Hub.Dispatch` (including drop-on-slow-subscriber).
- [ ] `dashboard.Broker` per-user filtering, `recompute()` union (admin → `all=true`),
      `UpdateScope`; `InterestBus` version increments.
- [ ] `processor`: dedup, fleet lookup, `UNASSIGNED`, invalid → DLQ, produce → dedup-set →
      commit ordering (franz-go `kfake`, `miniredis`).
- [ ] `model.Validate`; JWT issue/parse round-trip.
- [ ] `authz.Store` against PostgreSQL via testcontainers-go: scopes per demo user; re-seeding
      keeps admin reassignments.
- [ ] Web (Vitest): stream merge keeps newest `deviceTimestamp` per VIN; `format.ts` helpers.

---

## Reference: AWS trade-offs of this plan

Gains: ~20% cheaper compute (Graviton); no SCRAM secret and no MSK/EKS customer KMS keys; no
custom MSK configuration; topic settings explicit in code; stricter simulator TLS trust.

Costs: hand-written EKS Terraform instead of the module; self-managed EKS networking/DNS
components; no customer-controlled key for EKS secret encryption; dashboard-api may run on a
core node under pressure; the Lambda trade-offs in Phase 1.

## Open decisions for the user

- Approve Phase 2 items (especially 2.1 arm64, 2.2 EKS module replacement, 2.6 MSK IAM login,
  2.8 softer dashboard-api placement).
- Phase 4: should `deploy.sh` start Floci itself?
- Order: verify on AWS (Phase 3) before Floci, or go to Floci first?
- Phase 6: write unit tests now, later, or not at all?
