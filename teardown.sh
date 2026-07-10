#!/usr/bin/env bash
#
# teardown.sh — ecs-java-web-app FULL clean teardown (colleague account 825765391206)
# Handles every blocker class discovered across both labs:
#   - in-flight CodeDeploy deployments
#   - CODE_DEPLOY-controller service (scale to 0 via taskset drain not possible: we
#     stop deployments, then delete stack; service deletion handles tasks)
#   - versioned buckets (objects + versions + delete markers)
#   - ECR images blocking repo deletion
#   - RETAINED artifact bucket collision on redeploy
# Leaves the bootstrap layer intact (templates bucket, OIDC provider, SLRs,
# GitSync role + sync config, CodeConnections connection).
#
set -uo pipefail
export AWS_PAGER=""

REGION="eu-central-1"
STACK="ecs-java-web-app-stack"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

ARTIFACT_BUCKET="ecs-java-web-app-artifacts-${ACCOUNT}"
TEMPLATES_BUCKET="ecs-java-web-app-cfn-templates-${ACCOUNT}"   # retained on purpose
ECR_REPO="ecs-java-web-app"
CD_APP="ecs-java-web-app-codedeploy"
CD_GROUP="ecs-java-web-app-deployment-group"

echo "=================================================================="
echo " TEARDOWN ecs-java-web-app | account ${ACCOUNT} | ${REGION}"
echo "=================================================================="
if [ "${ACCOUNT}" != "825765391206" ]; then
  echo "WARNING: expected account 825765391206, got ${ACCOUNT}."
  read -p "Continue anyway? (y/N) " ANS
  [ "${ANS:-n}" = "y" ] || exit 1
fi

purge_bucket () {
  local B="$1"
  if ! aws s3api head-bucket --bucket "${B}" --region "${REGION}" >/dev/null 2>&1; then
    echo "   ${B}: absent (ok)"; return 0
  fi
  echo "   ${B}: purging..."
  aws s3 rm "s3://${B}" --recursive --region "${REGION}" >/dev/null 2>&1 || true
  local V M
  V=$(aws s3api list-object-versions --bucket "${B}" --region "${REGION}" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
  echo "${V}" | grep -q '"Key"' && aws s3api delete-objects --bucket "${B}" \
      --region "${REGION}" --delete "${V}" >/dev/null 2>&1 || true
  M=$(aws s3api list-object-versions --bucket "${B}" --region "${REGION}" \
      --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
  echo "${M}" | grep -q '"Key"' && aws s3api delete-objects --bucket "${B}" \
      --region "${REGION}" --delete "${M}" >/dev/null 2>&1 || true
  echo "   ${B}: purged."
}

echo
echo "[1/6] Stopping in-progress CodeDeploy deployments..."
DEPLOYMENTS=$(aws deploy list-deployments --application-name "${CD_APP}" \
  --deployment-group-name "${CD_GROUP}" \
  --include-only-statuses InProgress Created Queued Ready \
  --region "${REGION}" --query "deployments" --output text 2>/dev/null)
if [ -n "${DEPLOYMENTS:-}" ] && [ "${DEPLOYMENTS}" != "None" ]; then
  for D in ${DEPLOYMENTS}; do
    echo "   stopping ${D}"
    aws deploy stop-deployment --deployment-id "${D}" --auto-rollback-enabled \
      --region "${REGION}" >/dev/null 2>&1 || true
  done
else echo "   none."; fi

echo
echo "[2/6] Purging artifact bucket..."
purge_bucket "${ARTIFACT_BUCKET}"

echo
echo "[3/6] Emptying ECR repository..."
IMAGES=$(aws ecr list-images --repository-name "${ECR_REPO}" --region "${REGION}" \
  --query 'imageIds[*]' --output json 2>/dev/null)
if [ -n "${IMAGES:-}" ] && [ "${IMAGES}" != "[]" ] && [ "${IMAGES}" != "null" ]; then
  aws ecr batch-delete-image --repository-name "${ECR_REPO}" --region "${REGION}" \
    --image-ids "${IMAGES}" >/dev/null 2>&1 && echo "   images deleted." || echo "   skipped."
else echo "   empty/absent (ok)."; fi

echo
echo "[4/6] Deleting stack (up to 3 attempts)..."
ATTEMPT=1
while [ ${ATTEMPT} -le 3 ]; do
  echo "   attempt ${ATTEMPT}..."
  aws cloudformation delete-stack --stack-name "${STACK}" --region "${REGION}" 2>/dev/null
  if aws cloudformation wait stack-delete-complete --stack-name "${STACK}" --region "${REGION}" 2>/dev/null; then
    echo "   stack deleted."; break
  fi
  STATUS=$(aws cloudformation describe-stacks --stack-name "${STACK}" --region "${REGION}" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null)
  if [ -z "${STATUS:-}" ]; then echo "   stack gone."; break; fi
  echo "   status ${STATUS}; re-purging and retrying..."
  purge_bucket "${ARTIFACT_BUCKET}"
  IMAGES=$(aws ecr list-images --repository-name "${ECR_REPO}" --region "${REGION}" \
    --query 'imageIds[*]' --output json 2>/dev/null)
  [ -n "${IMAGES:-}" ] && [ "${IMAGES}" != "[]" ] && \
    aws ecr batch-delete-image --repository-name "${ECR_REPO}" --region "${REGION}" \
      --image-ids "${IMAGES}" >/dev/null 2>&1
  ATTEMPT=$((ATTEMPT+1))
done

echo
echo "[5/6] Removing retained artifact bucket (prevents redeploy collision)..."
purge_bucket "${ARTIFACT_BUCKET}"
aws s3 rb "s3://${ARTIFACT_BUCKET}" --region "${REGION}" 2>/dev/null \
  && echo "   removed." || echo "   already gone (ok)."

echo
echo "[6/6] Final state..."
FINAL=$(aws cloudformation describe-stacks --stack-name "${STACK}" --region "${REGION}" \
  --query "Stacks[0].StackStatus" --output text 2>&1)
echo "   stack status: ${FINAL}"
echo
echo "RETAINED (bootstrap layer for redeploy):"
echo "   - ${TEMPLATES_BUCKET} (templates)"
echo "   - OIDC provider, SLRs, GitSync role + sync config, GitHub connection"
echo "=================================================================="