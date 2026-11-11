#!/usr/bin/env bash
# CloudWatch alarms for the ForeignMenu backend, sent to the shared SNS topic chuanbei-ops-alerts (created
# here too if missing, with the same policy as the DateSeries repo's alarms.sh). Money alarms only. The
# account's cost budget lives in the DateSeries repo (infra/backend/alarms.sh), because the bill is shared. Idempotent; run by observability.sh, or on its own:
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
SERVER_ERROR_PCT="${SERVER_ERROR_PCT:-10}"         # 5xx share of requests in 15 min (and at least 3 of them)

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
# traffic) is fine; it emails on ALARM only (not again when it clears).
alarm() {
  local name="${APP}-$1" desc="$2" threshold="$3" period="$4" evals="$5" metrics="$6"
  aws cloudwatch put-metric-alarm --alarm-name "${name}" --alarm-description "${desc}" \
    --metrics "$(python3 -c 'import json,sys; m=json.loads(sys.argv[1]); p=int(sys.argv[2])
for x in m:
    if "MetricStat" in x: x["MetricStat"]["Period"]=p
print(json.dumps(m))' "${metrics}" "${period}")" \
    --threshold "${threshold}" --comparison-operator GreaterThanOrEqualToThreshold \
    --evaluation-periods "${evals}" --datapoints-to-alarm "${evals}" --treat-missing-data notBreaching \
    --alarm-actions "${TOPIC_ARN}"
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
alarm ai-cost-daily "AI cost (list price) above US\$${DAILY_AI_COST_USD} in the last 24 h. Dashboard → AI cost per day by model; top users table; saved query ForeignMenu/cost by model per day." \
  "${DAILY_AI_COST_USD}" 86400 1 "$(single "$(m m1 ForeignMenu CostUsd Sum)")"
alarm store-notification-failures "An App Store Server Notification failed on our side (answered 200 anyway, so Apple does NOT retry: fix and re-sync). Saved query ForeignMenu/subscription notifications." \
  1 300 1 "$(single "$(m m1 ForeignMenu StoreNotifications Sum outcome=error)")"

echo "== Retired alarms"
# 2026-11-11: only money alarms stay (DateSeries keeps the crash ones), so the account stays inside the free
# 10 alarm metrics. Throttle / latency / upstream-error alarms only ever fired on blips at this traffic; the
# dashboard still shows errors, and the daily AI-cost alarm catches credit farming that costs anything.
aws cloudwatch delete-alarms --alarm-names $(printf "${APP}-%s " lambda-errors lambda-throttles menu-p95-latency image-p95-latency \
  ai-upstream-errors dynamodb-throttles error-events anon-signup-limit)

echo
echo "Alerts go to SNS ${TOPIC_ARN}. Nobody is subscribed by this script. Subscribe an email (then confirm the link AWS sends):"
echo "  AWS_PROFILE=claude-agent aws sns subscribe --region ${REGION} --topic-arn ${TOPIC_ARN} --protocol email --notification-endpoint <your email>"
