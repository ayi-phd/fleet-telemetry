#!/usr/bin/env bash
# Destroys every resource created by deploy.sh.
#
#   ./destroy.sh          asks for confirmation
#   ./destroy.sh --yes    no prompt (CI)
#
# Order matters:
#   1. Platform stack: Kubernetes workloads, the web Service (which owns the NLB),
#      IoT things and device certificates.
#   2. Wait for AWS to finish deleting the NLB. Kubernetes deletes it asynchronously,
#      and a lingering NLB blocks subnet and VPC deletion.
#   3. Infra stack, retried because some AWS-managed ENIs (IoT VPC destination,
#      OpenSearch, EKS) are released minutes after their owner is gone.
# Safe to re-run after a partial failure.
set -Euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$ROOT/terraform/infra"
PLATFORM="$ROOT/terraform/platform"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[1;33m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }
tf()   { terraform -chdir="$1" "${@:2}"; }
has_state() { [[ -s "$1/terraform.tfstate" ]] && [[ -n "$(tf "$1" state list 2>/dev/null)" ]]; }

AUTO_APPROVE="${AUTO_APPROVE:-0}"
[[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]] && AUTO_APPROVE=1

for bin in terraform aws; do
  command -v "$bin" >/dev/null || die "'$bin' is not installed or not on PATH."
done
aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials are not configured. Run 'aws configure' or set AWS_PROFILE."

tf "$INFRA" init -input=false >/dev/null 2>&1 || die "terraform init failed in terraform/infra."
tf "$PLATFORM" init -input=false >/dev/null 2>&1 || die "terraform init failed in terraform/platform."

if ! has_state "$INFRA" && ! has_state "$PLATFORM"; then
  info "Nothing is deployed from this checkout. Nothing to destroy."
  exit 0
fi

# Region and names come from the infra state, so destroy always targets what deploy created.
REGION="$(tf "$INFRA" output -raw region 2>/dev/null || true)"
CLUSTER="$(tf "$INFRA" output -raw cluster_name 2>/dev/null || true)"
VPC_ID="$(tf "$INFRA" output -raw vpc_id 2>/dev/null || true)"
ACCOUNT="$(tf "$INFRA" output -raw account_id 2>/dev/null || true)"
[[ -n "$REGION" ]] && export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

if [[ "$AUTO_APPROVE" != "1" ]]; then
  printf '\nThis permanently deletes the fleet-telemetry platform in %s,\n' "${REGION:-the deployed region}"
  printf 'including all telemetry in OpenSearch and all data in PostgreSQL.\n\n'
  read -r -p "Type 'destroy' to continue: " answer
  [[ "$answer" == "destroy" ]] || { info "Cancelled. Nothing was changed."; exit 0; }
fi

# --------------------------------------------------------------------------
step "1/3: Removing workloads, the dashboard load balancer and simulated IoT devices"
if has_state "$PLATFORM"; then
  if ! tf "$PLATFORM" destroy -input=false -auto-approve; then
    # Usually means the EKS cluster is already gone, so the Kubernetes provider can't
    # connect. Kubernetes objects died with the cluster; forget them and destroy
    # the remaining AWS resources (IoT things and certificates).
    warn "Platform destroy failed. Retrying without Kubernetes objects (the cluster may already be gone)."
    tf "$PLATFORM" state list 2>/dev/null | grep -E '(^|\.)kubernetes_' | while read -r addr; do
      tf "$PLATFORM" state rm "$addr" >/dev/null
    done
    tf "$PLATFORM" destroy -input=false -auto-approve \
      || die "Couldn't destroy the platform stack. Fix the error above and run ./destroy.sh again."
  fi
else
  info "Platform stack not deployed; skipping."
fi

# --------------------------------------------------------------------------
step "2/3: Waiting for Kubernetes-created load balancers to be deleted"
k8s_load_balancers() {
  [[ -z "$CLUSTER" ]] && return 0
  aws resourcegroupstaggingapi get-resources \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --tag-filters "Key=kubernetes.io/cluster/$CLUSTER" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null | tr '\t' '\n' | grep -E '^arn:' || true
}
for _ in $(seq 1 30); do
  [[ -z "$(k8s_load_balancers)" ]] && break
  sleep 10
done
# Anything still there was orphaned (e.g. the cluster died before its controller ran). Delete it directly.
for arn in $(k8s_load_balancers); do
  warn "Deleting orphaned load balancer $arn"
  aws elbv2 delete-load-balancer --load-balancer-arn "$arn" || true
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$arn" 2>/dev/null || true
done
if [[ -n "$VPC_ID" ]]; then
  for tg in $(aws elbv2 describe-target-groups --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null); do
    aws elbv2 delete-target-group --target-group-arn "$tg" >/dev/null 2>&1 || true
  done
fi
info "No load balancers left in front of the cluster."

# --------------------------------------------------------------------------
step "3/3: Removing infrastructure (EKS, MSK, ElastiCache, RDS, OpenSearch, IoT rule, VPC)"
info "This takes 20-40 minutes."

cleanup_vpc_leftovers() {
  [[ -z "$VPC_ID" ]] && return 0
  # ENIs AWS has detached but not yet deleted keep subnets and security groups alive.
  for eni in $(aws ec2 describe-network-interfaces \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null); do
    info "Deleting detached network interface $eni"
    aws ec2 delete-network-interface --network-interface-id "$eni" >/dev/null 2>&1 || true
  done
  # Security groups created by Kubernetes' cloud provider (never by Terraform).
  for sg in $(aws ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-*" \
      --query 'SecurityGroups[].GroupId' --output text 2>/dev/null); do
    info "Deleting Kubernetes-created security group $sg"
    aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 || true
  done
}

if has_state "$INFRA"; then
  destroyed=0
  for attempt in 1 2 3; do
    if tf "$INFRA" destroy -input=false -auto-approve; then destroyed=1; break; fi
    warn "Attempt $attempt didn't finish; AWS is probably still releasing network interfaces."
    cleanup_vpc_leftovers
    [[ $attempt -lt 3 ]] && { info "Retrying in 60 seconds."; sleep 60; }
  done

  if [[ $destroyed -eq 0 ]]; then
    # The account-wide OpenSearch service-linked role can't be deleted while any other
    # OpenSearch domain in the account uses it. If that's all that's left, keep the role.
    remaining="$(tf "$INFRA" state list 2>/dev/null)"
    if [[ "$remaining" == "aws_iam_service_linked_role.opensearch[0]" ]]; then
      tf "$INFRA" state rm 'aws_iam_service_linked_role.opensearch[0]' >/dev/null
      warn "Kept the account-wide role AWSServiceRoleForAmazonOpenSearchService because other domains use it. It costs nothing."
      destroyed=1
    else
      die "Some infrastructure couldn't be deleted:
$remaining
Run ./destroy.sh again in a few minutes. If it keeps failing, the error above names the blocking resource."
    fi
  fi
else
  info "Infra stack not deployed; skipping."
fi

# --------------------------------------------------------------------------
rm -f "$INFRA/deploy.auto.tfvars.json" "$PLATFORM/deploy.auto.tfvars.json"
if [[ -n "$CLUSTER" ]] && command -v kubectl >/dev/null; then
  # deploy.sh ran `aws eks update-kubeconfig --alias $CLUSTER`, which names the cluster and user by ARN.
  arn="arn:aws:eks:$REGION:$ACCOUNT:cluster/$CLUSTER"
  kubectl config delete-context "$CLUSTER" >/dev/null 2>&1 || true
  kubectl config delete-cluster "$arn" >/dev/null 2>&1 || true
  kubectl config delete-user "$arn" >/dev/null 2>&1 || true
fi

cat <<EOF

$(printf '\033[1;32m')Everything deploy.sh created has been deleted.$(printf '\033[0m')

  KMS keys (MSK and EKS secret encryption) are scheduled for deletion. AWS enforces
  a waiting period of at least 7 days before removing them.
EOF
