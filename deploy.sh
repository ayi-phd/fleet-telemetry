#!/usr/bin/env bash
# Creates and starts the whole fleet-telemetry platform on AWS.
#
#   ./deploy.sh
#
# Safe to re-run: every step is idempotent, and re-running after a code change
# rebuilds the images under a new tag and rolls the Deployments.
#
# Settings (environment variables, all optional):
#   AWS_REGION           Region to deploy into                 (default: us-west-2)
#   AWS_PROFILE          Standard AWS CLI profile selection
#   PROJECT              Name prefix for every resource         (default: fleet-telemetry)
#   RESTRICT_TO_MY_IP=1  Allow only this machine's public IP to reach the EKS API and dashboard
#   IMAGE_TAG            Image tag to build and deploy          (default: <git sha or time>-<time>)
#
# Anything else can be tuned in terraform/infra/terraform.tfvars or
# terraform/platform/terraform.tfvars (see variables.tf in each stack).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$ROOT/terraform/infra"
PLATFORM="$ROOT/terraform/platform"
SERVICES=(telemetry-processor realtime-router dashboard-api rbac-authz vehicle-simulator)
LAMBDA_SERVICES=(iot-kafka-bridge) # built with --target runtime-lambda; not a Kubernetes Deployment

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
PROJECT="${PROJECT:-fleet-telemetry}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "deploy stopped at line $LINENO. Fix the problem above and run ./deploy.sh again; finished steps are skipped."' ERR

tf() { terraform -chdir="$1" "${@:2}"; }

# --------------------------------------------------------------------------
step "Checking tools and AWS credentials"
for bin in terraform aws docker kubectl curl; do
  command -v "$bin" >/dev/null || die "'$bin' is not installed or not on PATH."
done
docker buildx version >/dev/null 2>&1 || die "Docker Buildx is required (included with Docker Desktop and docker-buildx-plugin)."
docker info >/dev/null 2>&1 || die "Docker is installed but not running."
aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 \
  || die "AWS credentials are not configured. Run 'aws configure' or set AWS_PROFILE."
CALLER="$(aws sts get-caller-identity --query Arn --output text)"
info "Deploying as $CALLER"
info "Region $AWS_REGION, project $PROJECT"

# --------------------------------------------------------------------------
step "Stage 1/4: AWS infrastructure (VPC, EKS, MSK, ElastiCache, RDS, OpenSearch, IoT Core)"
info "A first run takes 40-60 minutes, mostly MSK and OpenSearch provisioning."
tf "$INFRA" init -input=false -upgrade >/dev/null
INFRA_STATE="$(tf "$INFRA" state list 2>/dev/null || true)"

# Refuse to silently move an existing deployment to another region.
if grep -q '^module.eks' <<<"$INFRA_STATE"; then
  deployed_region="$(tf "$INFRA" output -raw region 2>/dev/null || true)"
  if [[ -n "$deployed_region" && "$deployed_region" != "$AWS_REGION" ]]; then
    die "This checkout is already deployed in $deployed_region. Run with AWS_REGION=$deployed_region, or ./destroy.sh first."
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
if [[ "${RESTRICT_TO_MY_IP:-0}" == "1" ]]; then
  my_ip="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')" || die "Couldn't detect this machine's public IP."
  info "Restricting EKS API and dashboard access to $my_ip/32"
  allowed_json=",
  \"eks_public_access_cidrs\": [\"$my_ip/32\"],
  \"dashboard_allowed_cidrs\": [\"$my_ip/32\"]"
fi
cat > "$INFRA/deploy.auto.tfvars.json" <<EOF
{
  "region": "$AWS_REGION",
  "project": "$PROJECT",
  "create_opensearch_service_linked_role": $create_slr$allowed_json
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

cat > "$PLATFORM/deploy.auto.tfvars.json" <<EOF
{
  "image_tag": "$IMAGE_TAG"
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

URL="$(tf "$PLATFORM" output -raw dashboard_url)"
PASSWORD="$(tf "$PLATFORM" output -raw demo_password)"
HOST="${URL#http://}"
info "Waiting for the load balancer DNS name to resolve (usually 1-3 minutes)"
for _ in $(seq 1 36); do
  if curl -fsS -o /dev/null --max-time 5 "$URL/nginx-health" 2>/dev/null; then break; fi
  sleep 5
done
curl -fsS -o /dev/null --max-time 5 "$URL/nginx-health" 2>/dev/null \
  || info "The dashboard isn't reachable from here yet; $HOST may still be propagating."

cat <<EOF

$(printf '\033[1;32m')Fleet telemetry platform is running.$(printf '\033[0m')

  Dashboard   $URL
  Password    $PASSWORD   (same for every demo user)

  Demo users  admin            sees every fleet
              north-manager    fleet-north only
              south-viewer     fleet-south only
              vehicle-viewer   two individually granted vehicles

  Sign in as different users in separate browser profiles to see that each
  only receives the vehicles their permissions allow.

  OpenSearch Dashboards  $(tf "$INFRA" output -raw opensearch_dashboards_url)  (VPC-only)
  IoT rule errors        aws logs tail $(tf "$PLATFORM" output -raw iot_rule_error_log_group) --follow
  Service logs           kubectl -n $NAMESPACE logs -l app=telemetry-processor -f

  This stack costs money every hour it runs. Remove everything with ./destroy.sh
EOF
