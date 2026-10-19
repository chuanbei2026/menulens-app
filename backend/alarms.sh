#!/usr/bin/env bash
# CloudWatch alarms for the ForeignMenu backend, sent to the shared SNS topic chuanbei-ops-alerts (created
# here too if missing, with the same policy as the DateSeries repo's alarms.sh). The CloudFront alarm for
# api.chuanbei.dev and the account's cost budget live in the DateSeries repo (infra/backend/alarms.sh),
# because the distribution and the bill are shared. Idempotent; run by observability.sh, or on its own:
#
#   AWS_PROFILE=claude-agent ./alarms.sh
#   DAILY_AI_COST_USD=20 AWS_PROFILE=claude-agent ./alarms.sh        # thresholds are env vars, see below
#
# Nothing is subscribed to the topic here. To get the alerts by email (then confirm the link AWS sends):
#   AWS_PROFILE=claude-agent aws sns subscribe --region us-west-2 --topic-arn arn:aws:sns:us-west-2:<account>:chuanbei-ops-alerts --protocol email --notification-endpoint <you@example.com>
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
APP="ForeignMenu"
FN="foreignmenu-api"
TOPIC_NAME="chuanbei-ops-alerts"

# Thresholds (normal on 2026-10-19: /menu p95 ≈ 40 s, /image p95 ≈ 11 s, 20–800 requests a day).
DAILY_AI_COST_USD="${DAILY_AI_COST_USD:-10}"       # AI list-price cost in the last 24 h (menus + dish pictures)
MENU_P95_MS="${MENU_P95_MS:-120000}"               # /menu p95 over 15 min, twice in a row
IMAGE_P95_MS="${IMAGE_P95_MS:-45000}"              # /image p95 over 15 min, twice in a row
SERVER_ERROR_PCT="${SERVER_ERROR_PCT:-10}"         # 5xx share of requests in 15 min (and at least 3 of them)
AI_ERRORS_15MIN="${AI_ERRORS_15MIN:-3}"            # failed model calls (OpenAI or Bedrock) in 15 min
ANON_LIMIT_HITS_HOUR="${ANON_LIMIT_HITS_HOUR:-20}" # 429s from the per-IP device-account limit in an hour

aws() { command aws --region "${REGION}" "$@"; }
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

echo "== SNS topic ${TOPIC_NAME}"
TOPIC_ARN="$(aws sns create-topic --name "${TOPIC_NAME}" --query TopicArn --output text)"
# CloudWatch alarms of this account and AWS Budgets may publish; nobody else.
aws sns set-topic-attributes --topic-arn "${TOPIC_ARN}" --attribute-name Policy --attribute-value "$(cat <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"Owner","Effect":"Allow","Principal":{"AWS":"*"},"Action":["SNS:Publish","SNS:Subscribe","SNS:GetTopicAttributes","SNS:ListSubscriptionsByTopic"],
  "Resource":"${TOPIC_ARN}","Condition":{"StringEquals":{"AWS:SourceOwner":"${ACCOUNT_ID}"}}},
 {"Sid":"CloudWatchAlarms","Effect":"Allow","Principal":{"Service":"cloudwatch.amazonaws.com"},"Action":"SNS:Publish","Resource":"${TOPIC_ARN}",
  "Condition":{"StringEquals":{"AWS:SourceAccount":"${ACCOUNT_ID}"}}},
 {"Sid":"Budgets","Effect":"Allow","Principal":{"Service":"budgets.amazonaws.com"},"Action":"SNS:Publish","Resource":"${TOPIC_ARN}",
  "Condition":{"StringEquals":{"aws:SourceAccount":"${ACCOUNT_ID}"}}}]}
EOF
)"

# alarm <name> <description> <threshold> <period s> <evaluation periods> <metrics JSON>
# Every alarm: one metric-math expression "e" (or a single metric "m1") ≥ threshold; missing data (no
# traffic) is fine; it notifies on ALARM and on OK.
alarm() {
  local name="${APP}-$1" desc="$2" threshold="$3" period="$4" evals="$5" metrics="$6"
  aws cloudwatch put-metric-alarm --alarm-name "${name}" --alarm-description "${desc}" \
    --metrics "$(python3 -c 'import json,sys; m=json.loads(sys.argv[1]); p=int(sys.argv[2])
for x in m:
    if "MetricStat" in x: x["MetricStat"]["Period"]=p
print(json.dumps(m))' "${metrics}" "${period}")" \
    --threshold "${threshold}" --comparison-operator GreaterThanOrEqualToThreshold \
    --evaluation-periods "${evals}" --datapoints-to-alarm "${evals}" --treat-missing-data notBreaching \
    --alarm-actions "${TOPIC_ARN}" --ok-actions "${TOPIC_ARN}"
  echo "  ${name} ≥ ${threshold}"
}
# m <id> <namespace> <metric> <stat> [dim=value ...] → a MetricStat query (ReturnData only for a lone metric)
m() {
  local id="$1" ns="$2" name="$3" stat="$4"; shift 4
  python3 -c 'import json,sys
id, ns, name, stat, *dims = sys.argv[1:]
print(json.dumps({"Id": id, "ReturnData": False, "MetricStat": {"Metric": {"Namespace": ns, "MetricName": name,
  "Dimensions": [{"Name": d.split("=",1)[0], "Value": d.split("=",1)[1]} for d in dims]}, "Stat": stat, "Period": 300}}))' "${id}" "${ns}" "${name}" "${stat}" "$@"
}
expr() { python3 -c 'import json,sys; print(json.dumps({"Id": "e", "Expression": sys.argv[1], "Label": sys.argv[2], "ReturnData": True}))' "$1" "$2"; }
single() { python3 -c 'import json,sys; x=json.loads(sys.argv[1]); x["ReturnData"]=True; print(json.dumps([x]))' "$1"; }
list() { python3 -c 'import json,sys; print(json.dumps([json.loads(a) for a in sys.argv[1:]]))' "$@"; }

echo "== Alarms (${REGION})"
alarm 5xx-rate "5xx are more than ${SERVER_ERROR_PCT}% of requests (and at least 3) in 15 min. Dashboard ForeignMenu → 5xx by route; saved query ForeignMenu/errors (last hour)." \
  "${SERVER_ERROR_PCT}" 900 1 "$(list "$(m m1 ForeignMenu ServerErrors Sum)" "$(m m2 ForeignMenu Requests Sum)" \
  "$(expr 'IF(m1 >= 3, 100 * m1 / m2, 0)' '5xx %')")"
alarm lambda-errors "The Lambda failed (crash or timeout) at least twice in 15 min. Saved query ForeignMenu/errors (last hour)." \
  2 900 1 "$(single "$(m m1 AWS/Lambda Errors Sum FunctionName=${FN})")"
alarm lambda-throttles "Lambda throttled requests: the account's concurrency (1000, shared with DateSeries) ran out." \
  1 300 1 "$(single "$(m m1 AWS/Lambda Throttles Sum FunctionName=${FN})")"
alarm menu-p95-latency "/menu p95 above ${MENU_P95_MS} ms for 30 min (normal ≈ 40 s). Saved query ForeignMenu/slow requests; dashboard → latency p95 by model." \
  "${MENU_P95_MS}" 900 2 "$(single "$(m m1 ForeignMenu LatencyMs p95 'route=POST /menu')")"
alarm image-p95-latency "/image (dish pictures) p95 above ${IMAGE_P95_MS} ms for 30 min (normal ≈ 11 s). Saved query ForeignMenu/slow requests." \
  "${IMAGE_P95_MS}" 900 2 "$(single "$(m m1 ForeignMenu LatencyMs p95 'route=POST /image')")"
alarm ai-upstream-errors "At least ${AI_ERRORS_15MIN} model calls failed upstream (OpenAI or Bedrock) in 15 min. Saved query ForeignMenu/AI upstream failures." \
  "${AI_ERRORS_15MIN}" 900 1 "$(single "$(m m1 ForeignMenu ModelErrors Sum)")"
alarm ai-cost-daily "AI cost (list price) above US\$${DAILY_AI_COST_USD} in the last 24 h. Dashboard → AI cost per day by model; top users table; saved query ForeignMenu/cost by model per day." \
  "${DAILY_AI_COST_USD}" 86400 1 "$(single "$(m m1 ForeignMenu CostUsd Sum)")"
alarm dynamodb-throttles "DynamoDB throttled the accounts / ledger table, or a request saw a DynamoDB error. Dashboard → DynamoDB throttles & errors." \
  1 300 1 "$(list "$(m m1 AWS/DynamoDB ReadThrottleEvents Sum TableName=foreignmenu-accounts)" "$(m m2 AWS/DynamoDB WriteThrottleEvents Sum TableName=foreignmenu-accounts)" \
  "$(m m3 AWS/DynamoDB WriteThrottleEvents Sum TableName=foreignmenu-ledger)" "$(m m4 ForeignMenu DdbErrors Sum)" \
  "$(expr 'FILL(m1, 0) + FILL(m2, 0) + FILL(m3, 0) + FILL(m4, 0)' 'throttles + errors')")"
alarm store-notification-failures "An App Store Server Notification failed on our side (answered 200 anyway, so Apple does NOT retry: fix and re-sync). Saved query ForeignMenu/subscription notifications." \
  1 300 1 "$(single "$(m m1 ForeignMenu StoreNotifications Sum outcome=error)")"
alarm error-events "An ERROR event outside a request's status (settlement / ledger / purchase-record failure, gave up after retries). Saved query ForeignMenu/errors (last hour)." \
  1 300 1 "$(single "$(m m1 ForeignMenu ErrorEvents Sum)")"
alarm anon-signup-limit "At least ${ANON_LIMIT_HITS_HOUR} device-account signups refused by the per-IP limit in an hour: someone farming the 300 free credits? Saved query ForeignMenu/rate-limit hits." \
  "${ANON_LIMIT_HITS_HOUR}" 3600 1 "$(single "$(m m1 ForeignMenu AnonRateLimited Sum)")"

echo
echo "Alerts go to SNS ${TOPIC_ARN}. Nobody is subscribed by this script. Subscribe an email (then confirm the link AWS sends):"
echo "  AWS_PROFILE=claude-agent aws sns subscribe --region ${REGION} --topic-arn ${TOPIC_ARN} --protocol email --notification-endpoint <your email>"
