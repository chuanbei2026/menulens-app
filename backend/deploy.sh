#!/usr/bin/env bash
# Idempotent deploy of the ForeignMenu backend into the personal AWS account.
#
#   AWS_PROFILE=claude-agent ./deploy.sh
#
# Creates (if missing) / updates:
#   DynamoDB  foreignmenu-accounts (PK userId), foreignmenu-ledger (PK userId, SK at),
#             foreignmenu-promo (PK code, SK sk), foreignmenu-usage-daily (PK userId, SK day),
#             foreignmenu-purchases (PK userId, SK "<time>#<transactionId>") — on-demand
#   Secret    foreignmenu/session-key {"key": <random>} — signs our 30-day session tokens
#   IAM role  foreignmenu-api-role (with the ClaudeWorkloadBoundary permissions boundary)
#   Lambda    foreignmenu-api (Node.js) + Function URL in RESPONSE_STREAM mode
# The OpenAI key is read from the existing secret AwsLambdaKey/foreign-menu ({"key": "sk-…"}).
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
NAME="foreignmenu-api"
ACCOUNTS_TABLE="foreignmenu-accounts"
LEDGER_TABLE="foreignmenu-ledger"
PROMO_TABLE="foreignmenu-promo"
DAILY_TABLE="foreignmenu-usage-daily"
PURCHASES_TABLE="foreignmenu-purchases"
SESSION_SECRET_NAME="foreignmenu/session-key"
OPENAI_SECRET_ID="AwsLambdaKey/foreign-menu"
RUNTIME="${RUNTIME:-nodejs22.x}"
HERE="$(cd "$(dirname "$0")" && pwd)"

aws() { command aws --region "${REGION}" "$@"; }
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BOUNDARY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/ClaudeWorkloadBoundary"
echo "account ${ACCOUNT_ID}, region ${REGION}"

echo "== DynamoDB"
make_table() {  # name, key attribute definitions, key schema
  if ! aws dynamodb describe-table --table-name "$1" >/dev/null 2>&1; then
    aws dynamodb create-table --table-name "$1" --billing-mode PAY_PER_REQUEST \
      --attribute-definitions $2 --key-schema $3 >/dev/null
  fi
}
make_table "${ACCOUNTS_TABLE}" "AttributeName=userId,AttributeType=S" "AttributeName=userId,KeyType=HASH"
make_table "${LEDGER_TABLE}" "AttributeName=userId,AttributeType=S AttributeName=at,AttributeType=S" \
  "AttributeName=userId,KeyType=HASH AttributeName=at,KeyType=RANGE"
make_table "${PROMO_TABLE}" "AttributeName=code,AttributeType=S AttributeName=sk,AttributeType=S" \
  "AttributeName=code,KeyType=HASH AttributeName=sk,KeyType=RANGE"
make_table "${DAILY_TABLE}" "AttributeName=userId,AttributeType=S AttributeName=day,AttributeType=S" \
  "AttributeName=userId,KeyType=HASH AttributeName=day,KeyType=RANGE"
# Every purchase attempt per user (src/purchaseRecords.mjs); kept when an account is deleted.
make_table "${PURCHASES_TABLE}" "AttributeName=userId,AttributeType=S AttributeName=sk,AttributeType=S" \
  "AttributeName=userId,KeyType=HASH AttributeName=sk,KeyType=RANGE"
TABLE_ARNS=()
for t in "${ACCOUNTS_TABLE}" "${LEDGER_TABLE}" "${PROMO_TABLE}" "${DAILY_TABLE}" "${PURCHASES_TABLE}"; do
  aws dynamodb wait table-exists --table-name "${t}"
  # Balances are money-like: point-in-time recovery and deletion protection.
  # A brand-new table is still setting up backups for a minute: retry.
  for i in 1 2 3 4 5 6; do
    aws dynamodb update-continuous-backups --table-name "${t}" \
      --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true >/dev/null 2>&1 && break
    sleep 10
  done
  if [[ "$(aws dynamodb describe-table --table-name "${t}" --query Table.DeletionProtectionEnabled --output text)" != "True" ]]; then
    aws dynamodb update-table --table-name "${t}" --deletion-protection-enabled >/dev/null
    aws dynamodb wait table-exists --table-name "${t}"
  fi
  TABLE_ARNS+=("\"$(aws dynamodb describe-table --table-name "${t}" --query Table.TableArn --output text)\"")
done

# Per-IP counters of new anonymous accounts (src/anonymous.mjs) expire on their own.
if [[ "$(aws dynamodb describe-time-to-live --table-name "${PROMO_TABLE}" --query TimeToLiveDescription.TimeToLiveStatus --output text)" == "DISABLED" ]]; then
  aws dynamodb update-time-to-live --table-name "${PROMO_TABLE}" \
    --time-to-live-specification "Enabled=true,AttributeName=expiresEpoch" >/dev/null
fi

echo "== session signing secret"
if ! SESSION_SECRET_ARN="$(aws secretsmanager describe-secret --secret-id "${SESSION_SECRET_NAME}" --query ARN --output text 2>/dev/null)"; then
  # Generated here and sent straight to Secrets Manager; never printed or written to disk.
  SESSION_SECRET_ARN="$(aws secretsmanager create-secret --name "${SESSION_SECRET_NAME}" \
    --description "HMAC key for ForeignMenu session tokens" \
    --secret-string "{\"key\":\"$(openssl rand -base64 48 | tr -d '\n')\"}" --query ARN --output text)"
fi
OPENAI_SECRET_ARN="$(aws secretsmanager describe-secret --secret-id "${OPENAI_SECRET_ID}" --query ARN --output text)"

echo "== IAM role"
ROLE_NAME="${NAME}-role"
if ! ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text 2>/dev/null)"; then
  ROLE_ARN="$(aws iam create-role --role-name "${ROLE_NAME}" --permissions-boundary "${BOUNDARY_ARN}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --query Role.Arn --output text)"
  NEW_ROLE=1
fi
TABLES_JSON="$(IFS=,; echo "${TABLE_ARNS[*]}")"
aws iam put-role-policy --role-name "${ROLE_NAME}" --policy-name runtime --policy-document "$(cat <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
  "Resource":"arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/lambda/${NAME}:*"},
 {"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:Query","dynamodb:DeleteItem"],
  "Resource":[${TABLES_JSON}]},
 {"Effect":"Allow","Action":"secretsmanager:GetSecretValue","Resource":["${OPENAI_SECRET_ARN}","${SESSION_SECRET_ARN}",
  "arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:foreignmenu/siwa-key-*"]},
 {"Effect":"Allow","Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],
  "Resource":["arn:aws:bedrock:*::foundation-model/*","arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:inference-profile/*"]}]}
EOF
)"
[[ "${NEW_ROLE:-0}" == "1" ]] && { echo "  waiting for the new role to propagate"; sleep 12; }

echo "== Logs"
LOG_GROUP="/aws/lambda/${NAME}"
aws logs create-log-group --log-group-name "${LOG_GROUP}" >/dev/null 2>&1 || true
aws logs put-retention-policy --log-group-name "${LOG_GROUP}" --retention-in-days 90

echo "== Lambda code"
BUILD="$(mktemp -d)"
cp "${HERE}"/src/*.mjs "${BUILD}/"
(cd "${BUILD}" && zip -qr function.zip ./*.mjs)
ENV="Variables={ACCOUNTS_TABLE=${ACCOUNTS_TABLE},LEDGER_TABLE=${LEDGER_TABLE},PROMO_TABLE=${PROMO_TABLE},DAILY_TABLE=${DAILY_TABLE},PURCHASES_TABLE=${PURCHASES_TABLE},OPENAI_SECRET_ID=${OPENAI_SECRET_ARN},SESSION_SECRET_ARN=${SESSION_SECRET_ARN}}"
# A dense menu page on a reasoning model can take minutes; the app waits up to 7.
if aws lambda get-function --function-name "${NAME}" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "${NAME}" --zip-file "fileb://${BUILD}/function.zip" >/dev/null
  aws lambda wait function-updated-v2 --function-name "${NAME}"
  aws lambda update-function-configuration --function-name "${NAME}" --runtime "${RUNTIME}" \
    --timeout 600 --memory-size 256 --environment "${ENV}" >/dev/null
else
  for i in 1 2 3 4 5; do  # a brand-new role can take a few seconds before Lambda may assume it
    if aws lambda create-function --function-name "${NAME}" --runtime "${RUNTIME}" --role "${ROLE_ARN}" \
         --handler index.handler --zip-file "fileb://${BUILD}/function.zip" \
         --timeout 600 --memory-size 256 --environment "${ENV}" >/dev/null 2>"${BUILD}/err"; then break; fi
    grep -q "cannot be assumed" "${BUILD}/err" || { cat "${BUILD}/err"; exit 1; }
    sleep 8
  done
fi
aws lambda wait function-updated-v2 --function-name "${NAME}"
rm -rf "${BUILD}"

echo "== Function URL (streaming)"
if ! URL="$(aws lambda get-function-url-config --function-name "${NAME}" --query FunctionUrl --output text 2>/dev/null)"; then
  URL="$(aws lambda create-function-url-config --function-name "${NAME}" --auth-type NONE \
    --invoke-mode RESPONSE_STREAM --query FunctionUrl --output text)"
  # Public URL; every route except /auth/apple, /auth/anonymous, /models and the App Store
  # notifications checks our own session token.
  aws lambda add-permission --function-name "${NAME}" --statement-id public-url \
    --action lambda:InvokeFunctionUrl --principal "*" --function-url-auth-type NONE >/dev/null
  aws lambda add-permission --function-name "${NAME}" --statement-id public-url-invoke \
    --action lambda:InvokeFunction --principal "*" --invoked-via-function-url >/dev/null 2>&1 || true
fi

"${HERE}/observability.sh"

echo
echo "Deployed: ${URL}"
