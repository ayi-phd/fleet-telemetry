# PLAN.md: one stack for real AWS and Floci

**Status: proposal, not yet approved.** Nothing here is implemented. Items under "Already
decided" were explicitly chosen by the user; everything else needs the user's approval before
it's built. See "Decisions needed" at the end. CLAUDE.md has the general project context.

## Goal

Run the same platform on real AWS and on Floci (local AWS emulator, MacBook Air with 24 GB),
with as few Floci-specific differences as possible. Every change to the shared code path must
be acceptable on AWS; Floci-only differences are limited to configuration switches.

## Already decided by the user

- **IoT Core stays** for device ingestion, on AWS and on Floci.
- **MSK stays** for Kafka. On Floci, MSK is emulated (Floci backs it with a Kafka-compatible
  broker); Terraform still creates `aws_msk_cluster`.
- **IoT Core → Lambda → MSK on both AWS and Floci**, replacing the IoT rule's native Kafka
  action ("on real AWS too is fine for now"). Design in CLAUDE.md. The Lambda writes the
  **original protobuf bytes unchanged** as the Kafka record value; it decodes a copy only to
  read the VIN for the record key and sets the `ingest_ts` header.
- **Exactly two scripts**, `deploy.sh` and `destroy.sh`, for every target. Floci is a target
  switch inside them, not new scripts.

## How the Floci switch would work

- A `target` variable (`aws` | `floci`) in both Terraform stacks, set by `deploy.sh` into
  `deploy.auto.tfvars.json` like the other deploy-time settings.
- `TARGET=floci ./deploy.sh` and `./destroy.sh` (which reads the target from the saved tfvars).
- Default is `aws`; AWS behaviour is only changed by the shared changes below.

## Part 1: shared changes (same code on AWS and Floci)

Each item: the change, why Floci needs it, and the effect on AWS.

1. **arm64 everywhere.** Move EKS node groups to Graviton (`AL2023_ARM_64_STANDARD`,
   e.g. t4g.large for core, t4g.medium for edge), build all images and the Lambda for
   `linux/arm64`. *Floci:* k3s and Lambda containers on Apple Silicon are arm64.
   *AWS:* roughly 20% cheaper for comparable instances; all components support arm64.
2. **Replace the EKS module with plain resources**: `aws_eks_cluster`, `aws_eks_node_group`,
   cluster and node IAM roles. Admin access for the deployer via the cluster's
   `access_config { bootstrap_cluster_creator_admin_permissions = true }` instead of access
   entries with policy association. *Floci:* the module fetches a TLS certificate from the OIDC
   issuer (Floci's issuer isn't served) and uses access-policy association (not implemented).
   *AWS:* same behaviour, more Terraform to maintain by hand.
3. **No EKS add-ons block.** Rely on the self-managed VPC CNI, kube-proxy and CoreDNS that EKS
   installs by default. *Floci:* add-on APIs aren't implemented. *AWS:* those components are
   upgraded manually instead of as managed add-ons.
4. **No customer-managed KMS key for EKS secrets.** EKS envelope-encrypts Kubernetes API data
   by default with an AWS-owned key. *Floci:* encryption config isn't implemented.
   *AWS:* no control over or audit of that key; acceptable for this platform.
5. **Pod Identity → IRSA.** `aws_iam_openid_connect_provider` for the cluster issuer, created
   without a certificate fetch (thumbprint optional in current provider versions; if not,
   use a static thumbprint). Service-account annotations instead of Pod Identity associations.
   Now needed by every AWS-calling pod: telemetry-processor and realtime-router (MSK IAM),
   realtime-router and dashboard-api (OpenSearch). *Floci:* documents IRSA, not Pod Identity.
   *AWS:* fully supported; no functional loss.
6. **MSK login: SCRAM → IAM authentication** (port 9098). franz-go's AWS SASL mechanism with
   credentials from IRSA (pods) or the execution role (Lambda). IAM policies grant the needed
   `kafka-cluster:*` actions (connect, describe/create/read/write topics, consumer groups).
   *Floci:* SCRAM secret association is likely outside its MSK API. *AWS:* an improvement:
   removes the `AmazonMSK_*` secret, its KMS key, and password handling.
   Keep `KAFKA_TLS=false` + no SASL as a Floci fallback (already supported by the code).
7. **No custom MSK configuration.** Services create topics with explicit settings:
   partitions, `retention.ms` (72 h), `min.insync.replicas`, and a configurable
   **`KAFKA_REPLICATION_FACTOR`** (3 on AWS, 1 on Floci's single broker). The Lambda must not
   depend on auto-creation: `raw-telemetry` is created by telemetry-processor, which is
   deployed before the IoT rule. *Floci:* configuration API likely unsupported.
   *AWS:* no loss; topic settings become explicit in code.
8. **dashboard-api placement: hard node selector → preferred node affinity** plus the existing
   toleration. *Floci:* single k3s node has no `workload=edge` label. *AWS:* still runs on the
   dedicated edge nodes; under node pressure a pod could land on a core node.
9. **Remove the explicit NodePort security group rule.** The web Service's
   `loadBalancerSourceRanges` already makes Kubernetes open exactly the allowed client ranges
   (plus VPC health checks) on the node security group. *AWS:* no loss; verify on first AWS
   deploy that the in-tree NLB integration adds the rules to the nodes' security group.
10. **OpenSearch address as a full URL** (`OPENSEARCH_URL`, scheme + host + port) instead of a
    bare host. AWS: `https://vpc-…`; Floci: `http://…:<port>`. Keep SigV4 signing on both.
11. **Simulator trusts a CA from a file** (e.g. `IOT_CA_FILE`, mounted from a secret).
    AWS: Amazon Root CA 1 (public, can be committed); Floci: `/_floci/ca.pem`, fetched by
    `deploy.sh`. *AWS:* slightly stricter than today's system-roots trust.
12. **Redis address falls back to the configuration endpoint**:
    `coalesce(primary_endpoint_address, configuration_endpoint_address)`. *Floci:* for
    cluster-mode-disabled replication groups it fills only `ConfigurationEndpoint` (open
    issues floci-io/floci#2618, #2769), so today's output would be `:6379`. *AWS:* unchanged,
    and keeps working if Floci fixes the bug.
13. **IoT topic rule and the Lambda move to the platform stack**, because the Lambda image must
    be pushed first (already part of the Lambda design).

## Part 2: Floci-only switches (no effect on AWS)

| Area | Floci behaviour |
|---|---|
| Terraform provider | `deploy.sh` points the AWS provider and CLI at Floci, e.g. `AWS_ENDPOINT_URL=http://localhost:4566` |
| Credentials | `deploy.sh` creates an IAM user and access key in Floci (EKS login rejects `test`/`test`) |
| VPC | NAT gateways off (`CreateNatGateway` is unsupported); Floci's containers don't route through the VPC |
| ElastiCache | No `aws_elasticache_subnet_group` (`CreateCacheSubnetGroup` is unsupported); AWS keeps it, or the cache would land in the default VPC |
| Service endpoints | MSK, RDS, ElastiCache and OpenSearch addresses given to pods must use a hostname pods can resolve (the Floci container name, e.g. `floci`), not `localhost`. Use a Floci setting for the advertised hostname if one exists; otherwise the platform stack overrides the addresses |
| Floci configuration | k3s and Floci on the same Docker network (`FLOCI_SERVICES_DOCKER_NETWORK`, or `FLOCI_SERVICES_EKS_DOCKER_NETWORK`); `FLOCI_TLS_ENABLED=true` for IoT on 8883; `FLOCI_SERVICES_IOT_ENDPOINT_ADDRESS` set to a hostname pods can reach |
| ECR | Default `hostname` URI style; fallback `FLOCI_SERVICES_ECR_URI_STYLE=path`. k3s pulls via the `registries.yaml` mirror Floci writes |
| Dashboard access | `kubectl port-forward` to the web Service instead of an NLB URL; `deploy.sh` prints the command |
| Kafka / Redis security | TLS and login on if Floci supports them; otherwise `KAFKA_TLS=false`, no SASL, `REDIS_TLS=false`, no password |
| Sizing | One replica per service, Kafka replication factor 1; Docker Desktop memory about 12 GB |

## Part 3: to verify on first Floci run

| Question | Fallback if the answer is no |
|---|---|
| Does Floci have a setting for the hostname in the endpoints it returns? | Platform stack overrides MSK/RDS/ElastiCache/OpenSearch addresses on the Floci target |
| Does Floci's MSK accept IAM authentication? | Plaintext Kafka, no SASL, on Floci only |
| Do Floci's MSK and Valkey accept TLS? | Plaintext on Floci only |
| Does the Terraform AWS provider honour `AWS_ENDPOINT_URL`? | Explicit `endpoints {}` block in the provider, enabled on the Floci target |
| Does the OIDC provider resource accept no thumbprint (provider version)? | Static thumbprint |
| Does IoT deliver the protobuf bytes to the Lambda with `SELECT *` (Floci) / does AWS need `encode(*, 'base64')`? | Handler accepts raw bytes and the base64 JSON envelope (already in the Lambda design) |
| Do plain EKS node groups, IAM roles and the cluster's `access_config` succeed on Floci? | Skip node groups on the Floci target (k3s runs pods on its single node anyway) |
| Does Docker Desktop push to `*.dkr.ecr.<region>.localhost:4566`? | `FLOCI_SERVICES_ECR_URI_STYLE=path` |

## Summary of AWS trade-offs

Gains: about 20% cheaper compute (Graviton); no SCRAM secret, no MSK or EKS customer KMS keys,
no custom MSK configuration; topic settings explicit in code; stricter simulator TLS trust.

Costs: hand-written EKS Terraform instead of the community module; self-managed EKS networking
and DNS components instead of managed add-ons; no customer-controlled key for EKS secret
encryption; dashboard-api may run on a core node under pressure. The Lambda trade-offs
(device identity not proven by the Kafka key; possible reordering on retries) are in CLAUDE.md.

## Suggested implementation order

1. Get everything compiling (CLAUDE.md, step 1).
2. Add the iot-kafka-bridge Lambda (CLAUDE.md, step 2).
3. Apply the shared changes in Part 1.
4. Deploy to real AWS, verify end to end, destroy. This proves the shared path before Floci.
5. Add the Floci target (Part 2) to Terraform, `deploy.sh` and `destroy.sh`.
6. First Floci run: work through Part 3, apply fallbacks where needed.
7. Unit tests (CLAUDE.md, step 3) can proceed in parallel from step 2 onward.

## Decisions needed from the user

- Approve the shared changes in Part 1, especially: Graviton/arm64 on AWS (1), replacing the
  EKS module (2), MSK IAM authentication instead of SCRAM (6), and preferred rather than
  required placement for dashboard-api (8).
- Should `deploy.sh TARGET=floci` start Floci itself (e.g. with the required settings from
  Part 2), or expect an already running, correctly configured Floci?
- Implementation order above: prove on AWS first (step 4), or go to Floci first?
