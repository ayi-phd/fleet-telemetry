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

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
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
  curl -fsS --max-time 5 "$FLOCI_ENDPOINT/_floci/health" >/dev/null 2>&1 || die "Floci isn't reachable at $FLOCI_ENDPOINT.
This script expects Floci already running and configured; it does not start it.
  floci start --services iot,lambda,eks,kafka,elasticache,rds,opensearch,ecr,iam,sts
Also required: k3s and Floci sharing a Docker network, FLOCI_TLS_ENABLED=true, and
FLOCI_SERVICES_IOT_ENDPOINT_ADDRESS set to a hostname pods can resolve (default here: floci).
Set FLOCI_ENDPOINT if Floci isn't at http://localhost:4566."
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
tf "$INFRA" init -input=false -upgrade >/dev/null
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

# Make sure the tag we pushed is what ECR actually has, before Kubernetes tries to pull it.
for repo in "${SERVICES[@]}" "${LAMBDA_SERVICES[@]}" web; do
  aws ecr describe-images --repository-name "$PROJECT/$repo" --image-ids "imageTag=$IMAGE_TAG" >/dev/null \
    || die "Image $PROJECT/$repo:$IMAGE_TAG is missing from ECR after push."
done

# --------------------------------------------------------------------------
step "Stage 3/4: Deploying services to EKS"
aws eks update-kubeconfig --name "$CLUSTER" --alias "$CLUSTER" >/dev/null
info "kubectl context set to $CLUSTER"

if [[ "$TARGET" == "floci" ]]; then
  curl -fsS "$FLOCI_ENDPOINT/_floci/ca.pem" -o "$PLATFORM/floci-ca.pem" \
    || die "Couldn't fetch Floci's CA certificate from $FLOCI_ENDPOINT/_floci/ca.pem."
fi

cat > "$PLATFORM/deploy.auto.tfvars.json" <<EOF
{
  "image_tag": "$IMAGE_TAG",
  "target": "$TARGET"
}
EOF
tf "$PLATFORM" init -input=false -upgrade >/dev/null
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
