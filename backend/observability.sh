#!/usr/bin/env bash
# CloudWatch dashboard "ForeignMenu" and the saved Logs Insights queries. Run by deploy.sh; safe to run
# on its own (it only touches CloudWatch, never the Lambda):
#
#   AWS_PROFILE=claude-agent ./observability.sh
#
# Sources: the one JSON line per request in /aws/lambda/foreignmenu-api (Logs Insights: money, users),
# the ForeignMenu metric namespace those lines carry (EMF), AWS/Lambda and AWS/DynamoDB.
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
NAME="foreignmenu-api"
LOG_GROUP="/aws/lambda/${NAME}"
aws() { command aws --region "${REGION}" "$@"; }

echo "== Dashboard + saved queries"
DASH="$(python3 - "${REGION}" "${LOG_GROUP}" "${NAME}" <<'PY'
import json, sys
region, log_group, fn = sys.argv[1:4]
ns = "ForeignMenu"
routes = ["POST /menu", "POST /image", "POST /auth/apple", "GET /credits"]
def metric(name, stat="Sum", route=None, label=None):
    m = [ns, name] + (["route", route] if route else [])
    return m + [{"stat": stat, "label": label or (f"{route} " if route else "") + name}]
def widget(title, metrics, x, y, w=12, h=6, stacked=False):
    return {"type": "metric", "x": x, "y": y, "width": w, "height": h,
            "properties": {"title": title, "region": region, "view": "timeSeries", "stacked": stacked, "period": 300, "metrics": metrics}}
def logs(title, query, x, y, w, h, view="table"):
    return {"type": "log", "x": x, "y": y, "width": w, "height": h,
            "properties": {"title": title, "region": region, "view": view, "query": f"SOURCE '{log_group}' | {query}"}}
calls = 'filter msg = "request" and costUsd > 0'
widgets = [
    # Money first: what OpenAI costs us, and what was charged (1 credit = US$0.005 at list price).
    logs("OpenAI 花费（美元）与扣掉的分 · 所选时间段",
         f"{calls} | stats sum(costUsd) as openai_usd, sum(creditsCharged) as credits, sum(creditsCharged) * 0.005 as credits_usd,"
         " count(*) as calls, count_distinct(userId) as users", 0, 0, 16, 3),
    logs("按接口和模型", f"{calls} | stats sum(costUsd) as usd, sum(creditsCharged) as credits, count(*) as calls by route, model | sort usd desc",
         16, 0, 8, 3),
    logs("每天：OpenAI 花费（美元）", f"{calls} | stats sum(costUsd) as usd by bin(1d)", 0, 3, 12, 7, view="bar"),
    logs("用得最多的 10 个用户", f"{calls} | stats sum(costUsd) as usd, sum(creditsCharged) as credits, count(*) as calls by userId"
         " | sort usd desc | limit 10", 12, 3, 12, 7),
    widget("Requests by route", [metric("Requests", route=r) for r in routes], 0, 10),
    widget("Errors (5xx server, 4xx client — 402 = out of credits)", [metric("ServerErrors"), metric("ClientErrors")], 12, 10),
    widget("Menu page latency (ms)", [metric("LatencyMs", "p50", "POST /menu", "total p50"), metric("LatencyMs", "p90", "POST /menu", "total p90"),
                                      metric("TimeToFirstByteMs", "p50", "POST /menu", "first byte p50")], 0, 16),
    widget("Dish picture latency (ms)", [metric("LatencyMs", "p50", "POST /image", "p50"), metric("LatencyMs", "p90", "POST /image", "p90")], 12, 16),
    widget("Tokens", [metric("InputTokens", route="POST /menu"), metric("OutputTokens", route="POST /menu"),
                      metric("OutputTokens", route="POST /image")], 0, 22),
    widget("Credits charged", [metric("CreditsCharged", route="POST /menu"), metric("CreditsCharged", route="POST /image")], 12, 22, stacked=True),
    widget("Signups & monthly grants", [metric("Signups"), metric("MonthlyGrants")], 0, 28),
]
def lam(name, stat="Sum", label=None):
    return ["AWS/Lambda", name, "FunctionName", fn, {"stat": stat, "label": label or name}]
widgets += [
    # Throttles mean the account concurrency (10, shared with DateSeries) ran out: a multi-page scan uses several at once.
    widget("Lambda: invocations, errors, throttles", [lam("Invocations"), lam("Errors"), lam("Throttles")], 12, 28),
    widget("Lambda: concurrency (account limit 10, shared with DateSeries) and duration",
           [lam("ConcurrentExecutions", "Maximum", "concurrent (max)"),
            ["AWS/Lambda", "ConcurrentExecutions", {"stat": "Maximum", "label": "whole account (max)"}],
            lam("Duration", "p90", "duration p90 (ms)")], 0, 34),
]
tables = ["foreignmenu-accounts", "foreignmenu-ledger", "foreignmenu-promo", "foreignmenu-usage-daily"]
def ddb(name, table, stat="Sum"):
    return ["AWS/DynamoDB", name, "TableName", table, {"stat": stat, "label": f"{table.replace('foreignmenu-', '')} {name}"}]
widgets += [
    widget("DynamoDB throttles & errors", [ddb(n, t) for t in tables for n in ["ThrottledRequests", "SystemErrors", "UserErrors"]], 12, 34),
    widget("DynamoDB consumed capacity", [ddb(n, t) for t in tables for n in ["ConsumedReadCapacityUnits", "ConsumedWriteCapacityUnits"]], 0, 40),
    widget("DynamoDB work per request (from our logs)",
           [metric("DdbCalls", "Average", "POST /menu", "/menu calls per request"), metric("DdbMs", "Average", "POST /menu", "/menu DynamoDB ms"),
            metric("DdbConditionalFailures", label="conditional failures"), metric("DdbErrors", label="DynamoDB errors")], 12, 40),
]
print(json.dumps({"start": "-P7D", "widgets": widgets}))
PY
)"
aws cloudwatch put-dashboard --dashboard-name ForeignMenu --dashboard-body "${DASH}" >/dev/null

save_query() {  # name, query — update in place if it already exists
  local id
  id="$(aws logs describe-query-definitions --query-definition-name-prefix "$1" \
        --query "queryDefinitions[?name=='$1'].queryDefinitionId | [0]" --output text)"
  if [[ "${id}" == "None" || -z "${id}" ]]; then
    aws logs put-query-definition --name "$1" --log-group-names "${LOG_GROUP}" --query-string "$2" >/dev/null
  else
    aws logs put-query-definition --query-definition-id "${id}" --name "$1" --log-group-names "${LOG_GROUP}" --query-string "$2" >/dev/null
  fi
}
save_query "ForeignMenu/recent requests" \
  'filter msg = "request" | fields @timestamp, route, status, ms, userId, model, creditsCharged, costUsd, inputTokens, outputTokens, error | sort @timestamp desc | limit 100'
save_query "ForeignMenu/errors" \
  'filter level = "ERROR" or level = "WARN" | fields @timestamp, msg, route, status, userId, error, ref | sort @timestamp desc | limit 100'
save_query "ForeignMenu/cost and credits (pick a time range)" \
  'filter msg = "request" and costUsd > 0 | stats sum(costUsd) as usd, sum(creditsCharged) as credits, count(*) as calls, count_distinct(userId) as users by route, model'
save_query "ForeignMenu/menu latency percentiles" \
  'filter msg = "request" and route = "POST /menu" and status = 200 | stats count(*) as n, pct(ttfbMs, 50) as ttfbP50, pct(ms, 50) as p50, pct(ms, 90) as p90 by bin(1h)'
save_query "ForeignMenu/out of credits (402)" \
  'filter msg = "request" and status = 402 | stats count(*) as refusals by userId | sort refusals desc'

echo "Dashboard: https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards/dashboard/ForeignMenu"
