#!/usr/bin/env bash
#
# deploy.sh — ecs-java-web-app redeploy preflight (colleague account 825765391206)
# Verifies/fixes every prerequisite discovered across both labs, so the GitSync
# trigger provisions cleanly in ONE pass. Run in CloudShell (Frankfurt).
#
# THE ONE MANUAL STEP THIS CANNOT DO: the image pre-push (CloudShell has no
# Docker). The script tells you exactly when and what to run from WSL.
#
set -uo pipefail
export AWS_PAGER=""

REGION="eu-central-1"
STACK="ecs-java-web-app-stack"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

TEMPLATES_BUCKET="ecs-java-web-app-cfn-templates-${ACCOUNT}"
ARTIFACT_BUCKET="ecs-java-web-app-artifacts-${ACCOUNT}"
GITSYNC_ROLE="CloudFormationGitSyncRole"
INFRA_DIR="${1:-$HOME/ecs-java-infra}"
REPO_URL="https://github.com/peprah12git/ecs-java-infras.git"

WARN=0
ok ()   { echo "   OK    $1"; }
fixup (){ echo "   FIXED $1"; }
warn () { echo "   WARN  $1"; WARN=1; }

echo "=================================================================="
echo " DEPLOY PREFLIGHT ecs-java-web-app | account ${ACCOUNT} | ${REGION}"
echo "=================================================================="

# ---------- 1. infra repo present & current ----------
echo
echo "[1/7] Infra repo"
if [ -d "${INFRA_DIR}/.git" ]; then
  ( cd "${INFRA_DIR}" && git pull origin main >/dev/null 2>&1 ) && ok "repo pulled"
else
  git clone "${REPO_URL}" "${INFRA_DIR}" >/dev/null 2>&1 && fixup "repo cloned" || warn "clone failed"
fi

# ---------- 2. templates bucket ----------
echo
echo "[2/7] Templates bucket ${TEMPLATES_BUCKET}"
if aws s3api head-bucket --bucket "${TEMPLATES_BUCKET}" --region "${REGION}" >/dev/null 2>&1; then
  ok "exists"
else
  aws s3api create-bucket --bucket "${TEMPLATES_BUCKET}" --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null \
    && fixup "created" || warn "could not create"
fi

# ---------- 3. upload templates ----------
echo
echo "[3/7] Uploading templates"
if [ -f "${INFRA_DIR}/root-stack.yml" ]; then
  ( cd "${INFRA_DIR}" && \
    aws s3 sync ./templates "s3://${TEMPLATES_BUCKET}/templates/" --delete >/dev/null && \
    aws s3 cp root-stack.yml "s3://${TEMPLATES_BUCKET}/root-stack.yml" >/dev/null ) \
    && ok "synced" || warn "upload failed"
  # sanity: root-stack must reference the suffixed bucket
  if grep -q "cfn-templates-${ACCOUNT}" "${INFRA_DIR}/root-stack.yml"; then
    ok "root-stack TemplateURLs point at suffixed bucket"
  else
    warn "root-stack.yml TemplateURLs do NOT use ${TEMPLATES_BUCKET} — fix repo first"
  fi
  # sanity: oidc.yml policy must reference the suffixed bucket
  if grep -q "cfn-templates-${ACCOUNT}" "${INFRA_DIR}/templates/oidc.yml"; then
    ok "oidc.yml S3 policy points at suffixed bucket"
  else
    warn "templates/oidc.yml policy still unsuffixed — infra workflow will get AccessDenied"
  fi
else
  warn "repo missing root-stack.yml at ${INFRA_DIR}"
fi

# ---------- 4. SLRs ----------
echo
echo "[4/7] Service-linked roles"
for SLR in ecs.amazonaws.com ecs.application-autoscaling.amazonaws.com; do
  aws iam create-service-linked-role --aws-service-name "${SLR}" >/dev/null 2>&1 \
    && fixup "created ${SLR}" || ok "${SLR} present"
done

# ---------- 5. OIDC provider + GitSync role ----------
echo
echo "[5/7] OIDC provider & GitSync role"
aws iam list-open-id-connect-providers --output text | grep -q token.actions.githubusercontent.com \
  && ok "GitHub OIDC provider present" || warn "OIDC provider MISSING (oidc.yml may need to create it)"
if aws iam get-role --role-name "${GITSYNC_ROLE}" >/dev/null 2>&1; then
  ok "GitSync role exists"
  aws iam put-role-policy --role-name "${GITSYNC_ROLE}" --policy-name AllowTemplateBucketReadEcsLab \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::${TEMPLATES_BUCKET}/*\"}]}" \
    2>/dev/null && ok "template-bucket read ensured"
  aws iam list-attached-role-policies --role-name "${GITSYNC_ROLE}" --output text \
    | grep -q AdministratorAccess && ok "AdministratorAccess attached" \
    || warn "GitSync role lacks AdministratorAccess"
else
  warn "GitSync role missing — see runbook to create it"
fi

# ---------- 6. artifact bucket collision ----------
echo
echo "[6/7] Artifact-bucket collision check"
if aws s3api head-bucket --bucket "${ARTIFACT_BUCKET}" --region "${REGION}" >/dev/null 2>&1; then
  warn "LEFTOVER ${ARTIFACT_BUCKET} exists — PipelineStack WILL fail. Run teardown.sh first."
else
  ok "no leftover artifact bucket"
fi

# ---------- 7. stack state ----------
echo
echo "[7/7] Stack state"
STATUS=$(aws cloudformation describe-stacks --stack-name "${STACK}" --region "${REGION}" \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null)
case "${STATUS:-ABSENT}" in
  ABSENT|"") ok "no stack — GitSync will CREATE it (close any PR that guts gitSync-config.yml)";;
  UPDATE_ROLLBACK_COMPLETE|CREATE_COMPLETE|UPDATE_COMPLETE)
    ok "stack retryable (${STATUS}) — use 'Retry latest commit'";;
  ROLLBACK_COMPLETE) warn "ROLLBACK_COMPLETE — must delete first (teardown.sh)";;
  *IN_PROGRESS*) warn "stack busy (${STATUS}) — wait";;
  *) warn "stack in ${STATUS} — inspect";;
esac

echo
echo "=================================================================="
if [ ${WARN} -eq 0 ]; then
cat << 'NEXT'
 PREFLIGHT CLEAN. Deploy sequence:

 1. TRIGGER: Console -> CloudFormation -> Git sync -> "Retry latest commit"
    (or Create stack -> Sync from Git if no stack exists:
     deployment file gitSync-config.yml, template root-stack.yml,
     repo peprah12git/ecs-java-infras, branch main,
     role arn:aws:iam::<ACCOUNT>:role/service-role/CloudFormationGitSyncRole)

 2. IMAGE PRE-PUSH (critical — DesiredCount:1 chicken-and-egg):
    Watch nested stacks; the MOMENT ECRStack = CREATE_COMPLETE, run from WSL:
      aws ecr get-login-password --region eu-central-1 --profile Peprah \
        | docker login --username AWS --password-stdin <ACCOUNT>.dkr.ecr.eu-central-1.amazonaws.com
      docker push <ACCOUNT>.dkr.ecr.eu-central-1.amazonaws.com/ecs-java-web-app:latest
    (build first if the local image is gone:
      cd ~/Documents/java-web-app && docker build -t <ACCOUNT>.dkr.ecr.eu-central-1.amazonaws.com/ecs-java-web-app:latest .)

 3. Wait for all 8 nested stacks CREATE_COMPLETE + root UPDATE_COMPLETE.

 4. Verify GitHub secrets (once per account; already set if unchanged):
      app repo  AWS_ROLE_ARN = arn:aws:iam::<ACCOUNT>:role/GitHubActionsECRRole
      infra repo AWS_ROLE_ARN = arn:aws:iam::<ACCOUNT>:role/GitHubActionsInfraRole

 5. Validate pipeline: empty-commit push to app repo -> Actions green ->
    CodePipeline -> blue/green -> curl the ALB (name + lab name visible).
NEXT
else
  echo " PREFLIGHT HAS WARNINGS above — fix, re-run, then trigger."
fi
echo "=================================================================="