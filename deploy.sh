#!/usr/bin/env bash
# Creates and starts the whole fleet-telemetry platform on AWS.
#
#   ./deploy.sh
#
# Safe to re-run: every step is idempotent, and re-running after a code change
# rebuilds the images under a new tag and rolls the Deployments.
#
# Settings (environment variables, all optional):
#   TARGET               "aws" or "floci"                       (default: aws)
#   AWS_REGION           Region to deploy into                 (default: us-west-2, or Floci's)
#   AWS_PROFILE          Standard AWS CLI profile selection (TARGET=aws only)
#   PROJECT              Name prefix for every resource         (default: fleet-telemetry)
#   RESTRICT_TO_MY_IP=1  Allow only this machine's public IP to reach the EKS API and dashboard
#   IMAGE_TAG            Image tag to build and deploy          (default: <git sha or time>-<time>)
#   FLOCI_ENDPOINT       Floci's AWS emulator endpoint    (TARGET=floci; default: http://localhost:4566)
#   FLOCI_IOT_ENDPOINT   Hostname pods use to reach Floci's IoT emulation (TARGET=floci; default: floci)
#
# TARGET=floci expects an already-running, correctly configured Floci; this script
# never starts one itself. If it isn't reachable, it prints what to run.
#
# Anything else can be tuned in terraform/infra/terraform.tfvars or
# terraform/platform/terraform.tfvars (see variables.tf in each stack).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$ROOT/terraform/infra"
PLATFORM="$ROOT/terraform/platform"
SERVICES=(telemetry-processor realtime-router dashboard-api rbac-authz vehicle-simulator)
LAMBDA_SERVICES=(iot-kafka-bridge) # built with --target runtime-lambda; not a Kubernetes Deployment

TARGET="${TARGET:-aws}"
PROJECT="${PROJECT:-fleet-telemetry}"
# -upgrade makes `terraform init` re-check the module registry over the network on every
# run, even when an already-cached copy satisfies the version constraint - real work only
# on AWS (catching a genuinely newer module version), pure liability on Floci (a local,
# no-AWS-cost target that should be able to redeploy without internet once modules are
# already cached; confirmed on a live run that a temporary internet outage broke a Floci
# deploy here with no other reason to need the network at all).
INIT_UPGRADE_FLAG=""
[[ "$TARGET" == "aws" ]] && INIT_UPGRADE_FLAG="-upgrade"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[1;33m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "deploy stopped at line $LINENO. Fix the problem above and run ./deploy.sh again; finished steps are skipped."' ERR

tf() { terraform -chdir="$1" "${@:2}"; }

# Floci accepts its default test/test credentials for most calls but rejects them for
# EKS token generation, so a real (Floci-local) IAM user is needed for that specifically.
# The access key is created once and cached; it is meaningless outside this Floci.
floci_ensure_deploy_credentials() {
  local user="fleet-telemetry-floci-deploy"
  local keyfile="$ROOT/.floci-deploy-key"
  aws iam get-user --user-name "$user" >/dev/null 2>&1 \
    || aws iam create-user --user-name "$user" >/dev/null \
    || die "Couldn't create the Floci IAM user $user."
  aws iam attach-user-policy --user-name "$user" \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess >/dev/null 2>&1 || true
  if [[ ! -s "$keyfile" ]]; then
    aws iam create-access-key --user-name "$user" \
      --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text > "$keyfile" \
      || die "Couldn't create a Floci IAM access key for $user."
    chmod 600 "$keyfile"
  fi
  read -r floci_key_id floci_secret < "$keyfile"
  export AWS_ACCESS_KEY_ID="$floci_key_id" AWS_SECRET_ACCESS_KEY="$floci_secret"
  FLOCI_DEPLOY_USER="$user"
}

case "$TARGET" in
  aws|floci) ;;
  *) die "TARGET must be \"aws\" or \"floci\", got \"$TARGET\"." ;;
esac

# --------------------------------------------------------------------------
step "Checking tools"
for bin in terraform aws docker kubectl curl; do
  command -v "$bin" >/dev/null || die "'$bin' is not installed or not on PATH."
done
docker buildx version >/dev/null 2>&1 || die "Docker Buildx is required (included with Docker Desktop and docker-buildx-plugin)."
docker info >/dev/null 2>&1 || die "Docker is installed but not running."

if [[ "$TARGET" == "floci" ]]; then
  step "Checking Floci"
  FLOCI_ENDPOINT="${FLOCI_ENDPOINT:-http://localhost:4566}"
  FLOCI_IOT_ENDPOINT="${FLOCI_IOT_ENDPOINT:-floci}"
  FLOCI_CONTAINER="${FLOCI_CONTAINER:-floci}"
  floci_setup_help="This script expects Floci already running and configured; it does not start it.
The floci CLI (floci start) can't turn on its MQTT broker or publish the ports it needs, so
start the container directly instead:
  docker run -d --name floci \\
    -v /var/run/docker.sock:/var/run/docker.sock \\
    -v floci-data:/app/data \\
    -p 4566:4566 -p 1883:1883 -p 8883:8883 \\
    -e FLOCI_SERVICES_IOT_MQTT_AUTO_START=true \\
    floci/floci:latest /app/application -Dquarkus.http.host=0.0.0.0
Set FLOCI_ENDPOINT if Floci isn't at http://localhost:4566, or FLOCI_CONTAINER if it's not
named 'floci'."
  curl -fsS --max-time 5 "$FLOCI_ENDPOINT/_floci/health" >/dev/null 2>&1 || die "Floci isn't reachable at $FLOCI_ENDPOINT.
$floci_setup_help"
  # Floci exposes no API to report whether its MQTT broker is on: vehicle-simulator's
  # connections would otherwise retry forever without ever surfacing an error (confirmed on
  # a live run - PLAN.md Phase 4). Check the container directly instead.
  floci_env="$(docker inspect "$FLOCI_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)"
  floci_ports="$(docker inspect "$FLOCI_CONTAINER" --format '{{json .NetworkSettings.Ports}}' 2>/dev/null)"
  echo "$floci_env" | grep -qx 'FLOCI_SERVICES_IOT_MQTT_AUTO_START=true' \
    && echo "$floci_ports" | grep -q '"1883/tcp"' && echo "$floci_ports" | grep -q '"8883/tcp"' \
    || die "Floci is running but not configured for MQTT (needs FLOCI_SERVICES_IOT_MQTT_AUTO_START=true and ports 1883+8883 published).
$floci_setup_help"
  export AWS_ENDPOINT_URL="$FLOCI_ENDPOINT"
  AWS_REGION="${AWS_REGION:-us-east-1}"
  export AWS_DEFAULT_REGION="$AWS_REGION"
  export AWS_ACCESS_KEY_ID="test" AWS_SECRET_ACCESS_KEY="test"
  info "Floci reachable at $FLOCI_ENDPOINT"
  info "Region $AWS_REGION, project $PROJECT"

  step "Setting up an IAM user for EKS auth (Floci rejects test/test for it)"
  floci_ensure_deploy_credentials
  info "Deploying as $FLOCI_DEPLOY_USER"
else
  AWS_REGION="${AWS_REGION:-us-west-2}"
  export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
  step "Checking AWS credentials"
  aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 \
    || die "AWS credentials are not configured. Run 'aws configure' or set AWS_PROFILE."
  CALLER="$(aws sts get-caller-identity --query Arn --output text)"
  info "Deploying as $CALLER"
  info "Region $AWS_REGION, project $PROJECT"
fi

# --------------------------------------------------------------------------
step "Stage 1/4: AWS infrastructure (VPC, EKS, MSK, ElastiCache, RDS, OpenSearch, IoT Core)"
[[ "$TARGET" == "aws" ]] && info "A first run takes 40-60 minutes, mostly MSK and OpenSearch provisioning."
tf "$INFRA" init -input=false $INIT_UPGRADE_FLAG >/dev/null
INFRA_STATE="$(tf "$INFRA" state list 2>/dev/null || true)"

# Refuse to silently move an existing deployment to another region or target.
if grep -q '^aws_eks_cluster.this' <<<"$INFRA_STATE"; then
  deployed_region="$(tf "$INFRA" output -raw region 2>/dev/null || true)"
  if [[ -n "$deployed_region" && "$deployed_region" != "$AWS_REGION" ]]; then
    die "This checkout is already deployed in $deployed_region. Run with AWS_REGION=$deployed_region, or ./destroy.sh first."
  fi
  deployed_target="$(tf "$INFRA" output -raw target 2>/dev/null || echo aws)"
  if [[ "$deployed_target" != "$TARGET" ]]; then
    die "This checkout is already deployed with TARGET=$deployed_target. Run ./destroy.sh first before switching targets."
  fi
fi

# The OpenSearch service-linked role is account-wide. Create it only if it doesn't
# exist yet, but keep managing it if an earlier run of this stack created it.
if grep -q 'aws_iam_service_linked_role.opensearch' <<<"$INFRA_STATE"; then
  create_slr=true
elif aws iam get-role --role-name AWSServiceRoleForAmazonOpenSearchService >/dev/null 2>&1; then
  create_slr=false
else
  create_slr=true
fi

# Persist deploy-time settings as auto-loaded tfvars so destroy.sh (and any
# later terraform command) sees exactly the same values.
allowed_json=""
if [[ "$TARGET" == "aws" && "${RESTRICT_TO_MY_IP:-0}" == "1" ]]; then
  my_ip="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')" || die "Couldn't detect this machine's public IP."
  info "Restricting EKS API and dashboard access to $my_ip/32"
  allowed_json=",
  \"eks_public_access_cidrs\": [\"$my_ip/32\"],
  \"dashboard_allowed_cidrs\": [\"$my_ip/32\"]"
fi
iot_endpoint_json=""
[[ "$TARGET" == "floci" ]] && iot_endpoint_json=",
  \"iot_endpoint_override\": \"$FLOCI_IOT_ENDPOINT\""
cat > "$INFRA/deploy.auto.tfvars.json" <<EOF
{
  "region": "$AWS_REGION",
  "project": "$PROJECT",
  "target": "$TARGET",
  "create_opensearch_service_linked_role": $create_slr$allowed_json$iot_endpoint_json
}
EOF

tf "$INFRA" apply -input=false -auto-approve

REGISTRY="$(tf "$INFRA" output -raw ecr_registry)"
CLUSTER="$(tf "$INFRA" output -raw cluster_name)"
NAMESPACE="$(tf "$INFRA" output -raw kubernetes_namespace)"

# --------------------------------------------------------------------------
step "Stage 2/4: Building and pushing container images"
if [[ -z "${IMAGE_TAG:-}" ]]; then
  sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo build)"
  IMAGE_TAG="${sha}-$(date -u +%Y%m%d%H%M%S)"
fi
info "Tag $IMAGE_TAG -> $REGISTRY"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null

# EKS node groups and the Lambda are arm64 (Graviton; also what Floci's k3s and Lambda
# containers run on Apple Silicon). The Dockerfiles cross-compile, so this is just as
# fast from an amd64 builder.
build() { # <repo name> <dockerfile> <context> [build args...]
  local repo="$1" file="$2" context="$3"; shift 3
  info "Building $repo"
  docker buildx build --platform linux/arm64 --provenance=false --push \
    -f "$file" -t "$REGISTRY/$PROJECT/$repo:$IMAGE_TAG" "$@" "$context" \
    >"$ROOT/.build-$repo.log" 2>&1 \
    || { tail -n 40 "$ROOT/.build-$repo.log" >&2; die "Image build for $repo failed (full log: .build-$repo.log)."; }
  rm -f "$ROOT/.build-$repo.log"
}
for svc in "${SERVICES[@]}"; do
  build "$svc" "$ROOT/services/Dockerfile" "$ROOT" --target runtime-standard --build-arg "SERVICE=$svc"
done
for svc in "${LAMBDA_SERVICES[@]}"; do
  build "$svc" "$ROOT/services/Dockerfile" "$ROOT" --target runtime-lambda --build-arg "SERVICE=$svc"
done
build web "$ROOT/web/Dockerfile" "$ROOT/web"

# Make sure the tag we pushed is what the registry actually has, before Kubernetes
# tries to pull it. Floci: confirmed on a live run that its ECR control-plane API
# (DescribeImages) doesn't reflect what its registry actually serves - a push that
# succeeds and pulls fine by tag still shows as absent there - so check the registry
# itself (docker pull, the same mechanism kubelet uses) instead (PLAN.md Phase 4).
for repo in "${SERVICES[@]}" "${LAMBDA_SERVICES[@]}" web; do
  if [[ "$TARGET" == "floci" ]]; then
    docker pull "$REGISTRY/$PROJECT/$repo:$IMAGE_TAG" >/dev/null \
      || die "Image $PROJECT/$repo:$IMAGE_TAG is missing from the registry after push."
  else
    aws ecr describe-images --repository-name "$PROJECT/$repo" --image-ids "imageTag=$IMAGE_TAG" >/dev/null \
      || die "Image $PROJECT/$repo:$IMAGE_TAG is missing from ECR after push."
  fi
done

# --------------------------------------------------------------------------
step "Stage 3/4: Deploying services to EKS"
aws eks update-kubeconfig --name "$CLUSTER" --alias "$CLUSTER" >/dev/null
info "kubectl context set to $CLUSTER"

if [[ "$TARGET" == "floci" ]]; then
  # Floci's own containers (the ECR registry, MSK, OpenSearch, Valkey, ...) sit on
  # Docker's plain default bridge network, which has no embedded DNS - confirmed on a
  # live run that neither containerd (pulling images) nor pods can resolve another
  # container by name there, even though they reach each other fine by IP. Worse,
  # Kafka's protocol advertises MSK's broker container name (a randomly-suffixed
  # "floci-msk-XXXXXX", not derivable from any Terraform output) in its metadata
  # responses, so even a bootstrap address given as a plain IP isn't enough (PLAN.md
  # Phase 4). Discover every "floci-*" container and its IP dynamically instead of
  # guessing names. k3s's own node container is recreated on every apply (Floci
  # re-deploys always recreate the EKS cluster; see PLAN.md's accepted Option (c)),
  # so this runs, and re-patches both places below, on every deploy.
  node_container="floci-eks-$PROJECT"
  floci_hosts="" # newline-separated "ip name" pairs, no indentation (added by consumers)
  add_floci_host() {
    local cname="$1" hostname="$2"
    local ip
    ip="$(docker inspect "$cname" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)"
    [[ -z "$ip" ]] && return
    if [[ -z "$floci_hosts" ]]; then
      floci_hosts="$ip $hostname"
    else
      floci_hosts="$(printf '%s\n%s' "$floci_hosts" "$ip $hostname")"
    fi
  }
  while read -r cname; do
    [[ "$cname" == "$node_container" ]] && continue
    add_floci_host "$cname" "$cname"
  done < <(docker ps --format '{{.Names}}' | grep '^floci-')
  # The main Floci gateway container itself (plain "floci", not "floci-*") is where
  # the vehicle-simulator's MQTT connection actually needs to land - confirmed on a
  # live run that IOT_ENDPOINT ("floci" by default, from FLOCI_IOT_ENDPOINT) never
  # resolved from a pod because the loop above only ever matched the "floci-*"
  # prefix, so it was silently never patched (PLAN.md Phase 4).
  add_floci_host "$FLOCI_CONTAINER" "$FLOCI_IOT_ENDPOINT"

  if docker inspect "$node_container" >/dev/null 2>&1; then
    while read -r ip cname; do
      docker exec "$node_container" sh -c "grep -q '[[:space:]]$cname\$' /etc/hosts || echo '$ip $cname' >> /etc/hosts"
    done <<< "$floci_hosts"
  else
    warn "Couldn't find the Floci EKS node container ($node_container) to patch /etc/hosts; image pulls may fail to resolve."
  fi

  # The node-level /etc/hosts entries above only help containerd's image pulls (which
  # use the node's own DNS); pods resolve names through cluster CoreDNS instead, which
  # doesn't consult the node's /etc/hosts (k3s's own NodeHosts ConfigMap key is its
  # cluster-node registry, not a copy of /etc/hosts, and gets overwritten by k3s - a
  # dead end confirmed on a live run). Patching the same entries into CoreDNS's
  # Corefile as a "hosts" block does survive, since k3s doesn't reconcile that key.
  corefile=$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' 2>/dev/null) && [[ -n "$corefile" ]] || die "Couldn't read the CoreDNS Corefile to patch in Floci's container hostnames."
  node_hosts=$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.NodeHosts}' 2>/dev/null)
  if [[ -n "$floci_hosts" ]]; then
    tmp_entries="$(mktemp)"
    tmp_corefile="$(mktemp)"
    printf '%s\n' "$floci_hosts" | sed 's/^/      /' > "$tmp_entries"
    # sed's `r` command inserts a file's content after the matched line - unlike a
    # substitution replacement, this has no issue with the inserted text spanning
    # multiple lines, and is portable to BSD/macOS sed (which choked on this both as
    # a multi-line `s///` replacement and as a multi-line `awk -v` string, tried
    # first; a live run on this exact tool is what caught both).
    sed -e "/hosts \/etc\/coredns\/NodeHosts {/r $tmp_entries" <<<"$corefile" > "$tmp_corefile"
    rm -f "$tmp_entries"
    if [[ -s "$tmp_corefile" ]]; then
      kubectl -n kube-system create configmap coredns \
        --from-file=Corefile="$tmp_corefile" --from-literal=NodeHosts="$node_hosts" \
        --dry-run=client -o yaml | kubectl -n kube-system apply -f - >/dev/null
    else
      warn "Patching Floci's container hostnames into CoreDNS produced an empty Corefile; left it untouched."
    fi
    rm -f "$tmp_corefile"
  fi
  kubectl -n kube-system rollout restart deployment coredns >/dev/null
  kubectl -n kube-system rollout status deployment coredns --timeout=60s >/dev/null \
    || warn "CoreDNS didn't roll out after patching in Floci's hostnames; pod-level DNS for them may still fail."
fi

floci_creds_json=""
if [[ "$TARGET" == "floci" ]]; then
  # Not fatal: no confirmed real endpoint for this exists on Floci 1.5.x (this path
  # 404s as an S3 NoSuchBucket, i.e. isn't routed as a Floci endpoint at all). The
  # platform stack already falls back to the committed Amazon Root CA 1 when this
  # file is absent (terraform/platform/simulator.tf), so the simulator still starts;
  # its MQTT TLS trust just won't verify Floci's own broker cert until a real
  # mechanism for this is found (PLAN.md Phase 4).
  curl -fsS "$FLOCI_ENDPOINT/_floci/ca.pem" -o "$PLATFORM/floci-ca.pem" 2>/dev/null \
    || warn "Couldn't fetch a Floci CA certificate from $FLOCI_ENDPOINT/_floci/ca.pem; falling back to the committed Amazon Root CA 1 (won't verify Floci's broker cert)."
  # Floci's EKS emulation has no OIDC identity, so IRSA can't work there; realtime-router
  # and dashboard-api use this IAM user's key as static OpenSearch credentials instead
  # (see terraform/infra/iam_pods.tf and terraform/platform/main.tf).
  # floci_hosts (built above) also goes to iot-kafka-bridge as an env var, so it can
  # patch its own /etc/hosts at startup: its execution containers sit outside the k3s
  # cluster, so the node/CoreDNS patching above never reaches them, yet Kafka's protocol
  # advertises MSK's randomly-suffixed container name in its metadata responses, so even
  # an IP bootstrap address isn't enough for the produce request that follows (confirmed
  # on a live run - PLAN.md Phase 4).
  floci_creds_json=",
  \"floci_deploy_access_key_id\": \"$floci_key_id\",
  \"floci_deploy_secret_access_key\": \"$floci_secret\",
  \"floci_extra_hosts\": \"${floci_hosts//$'\n'/\\n}\""
fi

cat > "$PLATFORM/deploy.auto.tfvars.json" <<EOF
{
  "image_tag": "$IMAGE_TAG",
  "target": "$TARGET"$floci_creds_json
}
EOF
tf "$PLATFORM" init -input=false $INIT_UPGRADE_FLAG >/dev/null
tf "$PLATFORM" apply -input=false -auto-approve

# --------------------------------------------------------------------------
step "Stage 4/4: Checking the pipeline"
for d in rbac-authz telemetry-processor realtime-router dashboard-api web; do
  kubectl -n "$NAMESPACE" rollout status "deployment/$d" --timeout=5m >/dev/null \
    || die "Deployment $d did not become ready. Inspect it with: kubectl -n $NAMESPACE describe deployment $d"
done
info "All services are ready."

DASHBOARD="$(tf "$PLATFORM" output -raw dashboard_url)"
PASSWORD="$(tf "$PLATFORM" output -raw demo_password)"

extra_lines=""
if [[ "$TARGET" == "aws" ]]; then
  HOST="${DASHBOARD#http://}"
  info "Waiting for the load balancer DNS name to resolve (usually 1-3 minutes)"
  for _ in $(seq 1 36); do
    if curl -fsS -o /dev/null --max-time 5 "$DASHBOARD/nginx-health" 2>/dev/null; then break; fi
    sleep 5
  done
  curl -fsS -o /dev/null --max-time 5 "$DASHBOARD/nginx-health" 2>/dev/null \
    || info "The dashboard isn't reachable from here yet; $HOST may still be propagating."
  extra_lines="
  OpenSearch Dashboards  $(tf "$INFRA" output -raw opensearch_dashboards_url)  (VPC-only)
  IoT rule errors        aws logs tail $(tf "$PLATFORM" output -raw iot_rule_error_log_group) --follow"
fi

cat <<EOF

$(printf '\033[1;32m')Fleet telemetry platform is running.$(printf '\033[0m')

  Dashboard   $DASHBOARD
  Password    $PASSWORD   (same for every demo user)

  Demo users  admin            sees every fleet
              north-manager    fleet-north only
              south-viewer     fleet-south only
              vehicle-viewer   two individually granted vehicles

  Sign in as different users in separate browser profiles to see that each
  only receives the vehicles their permissions allow.
$extra_lines
  Service logs           kubectl -n $NAMESPACE logs -l app=telemetry-processor -f
EOF
if [[ "$TARGET" == "aws" ]]; then
  cat <<EOF

  This stack costs money every hour it runs. Remove everything with ./destroy.sh
EOF
else
  cat <<EOF

  Remove everything (Floci itself keeps running) with TARGET=floci ./destroy.sh
EOF
fi
