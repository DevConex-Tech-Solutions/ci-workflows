#!/usr/bin/env bash
# One-time AWS setup for the shared Vercel deploy workflow.
#
# Creates (or updates):
#   1. the GitHub OIDC identity provider in your AWS account (if missing)
#   2. an IAM role that GitHub Actions in your org can assume
#   3. an SSM SecureString parameter holding the Vercel access token
# Then rewrites the aws_role_arn and aws_region defaults in the reusable workflow.
#
# Usage, from the repo root, with AWS admin credentials active in your shell:
#   bash aws/setup.sh [region]
set -euo pipefail

REGION="${1:-${AWS_REGION:-us-east-1}}"
ORG="DevConex-Tech-Solutions"
ROLE_NAME="github-vercel-deploy"
PARAM_NAME="/devconex/vercel/token"
PROVIDER_HOST="token.actions.githubusercontent.com"
WORKFLOW_FILE=".github/workflows/vercel-deploy.yml"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${PROVIDER_HOST}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo "AWS account: ${ACCOUNT_ID}"
echo "Identity:    ${CALLER_ARN}"
echo "Region:      ${REGION}"
echo "GitHub org:  ${ORG}"
read -r -p "Create or update the OIDC provider, role '${ROLE_NAME}' and parameter '${PARAM_NAME}' here? [y/N] " CONFIRM
if [ "${CONFIRM}" != "y" ]; then
  echo "Aborted."
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "1/4 OIDC provider"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${PROVIDER_ARN}" >/dev/null 2>&1; then
  echo "    already exists"
else
  aws iam create-open-id-connect-provider \
    --url "https://${PROVIDER_HOST}" \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
  echo "    created"
fi

cat > "${WORKDIR}/trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${PROVIDER_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": { "${PROVIDER_HOST}:aud": "sts.amazonaws.com" },
        "StringLike": {
          "${PROVIDER_HOST}:sub": [
            "repo:${ORG}/*:ref:refs/heads/main",
            "repo:${ORG}/*:pull_request"
          ]
        }
      }
    }
  ]
}
EOF

cat > "${WORKDIR}/policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ssm:GetParameter",
      "Resource": "arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter${PARAM_NAME}"
    }
  ]
}
EOF

echo "2/4 IAM role"
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "${ROLE_NAME}" --policy-document "file://${WORKDIR}/trust.json"
  echo "    updated trust policy on existing role"
else
  aws iam create-role --role-name "${ROLE_NAME}" --assume-role-policy-document "file://${WORKDIR}/trust.json" --max-session-duration 3600 >/dev/null
  echo "    created"
fi
aws iam put-role-policy --role-name "${ROLE_NAME}" --policy-name read-vercel-token --policy-document "file://${WORKDIR}/policy.json"

echo "3/4 Vercel token in SSM (${PARAM_NAME}, ${REGION})"
read -r -s -p "    Paste the Vercel access token (input hidden): " VERCEL_TOKEN_VALUE
echo
if [ -z "${VERCEL_TOKEN_VALUE}" ]; then
  echo "Empty token. Aborted."
  exit 1
fi
aws ssm put-parameter --region "${REGION}" --name "${PARAM_NAME}" --type SecureString --value "${VERCEL_TOKEN_VALUE}" --overwrite >/dev/null
unset VERCEL_TOKEN_VALUE
echo "    stored"

echo "4/4 Workflow defaults"
if [ -f "${WORKFLOW_FILE}" ]; then
  sed -i.bak "s|arn:aws:iam::ACCOUNT_ID:role/${ROLE_NAME}|${ROLE_ARN}|" "${WORKFLOW_FILE}"
  sed -i.bak "s|default: \"us-east-1\"|default: \"${REGION}\"|" "${WORKFLOW_FILE}"
  rm -f "${WORKFLOW_FILE}.bak"
  echo "    updated ${WORKFLOW_FILE}"
else
  echo "    ${WORKFLOW_FILE} not found. Set aws_role_arn to ${ROLE_ARN} and aws_region to ${REGION} by hand."
fi

echo
echo "Done. Role ARN: ${ROLE_ARN}"
echo "Next: commit the workflow change, then tag it:"
echo "  git add -A && git commit -m 'Configure AWS role' && git push"
echo "  git tag -f v1 && git push -f origin v1"
