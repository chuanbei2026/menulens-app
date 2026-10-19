#!/usr/bin/env bash
# Ops for the ForeignMenu backend: log retention, one log metric filter, the CloudWatch dashboard
# "ForeignMenu", the saved Logs Insights queries, then the alarms (alarms.sh). Run by deploy.sh; safe to
# run on its own, any number of times (it only touches CloudWatch / Logs / SNS, never the Lambda):
#
#   AWS_PROFILE=claude-agent ./observability.sh
#
# Sources: the one JSON line per request in /aws/lambda/foreignmenu-api (Logs Insights: money, users),
# the ForeignMenu metric namespace those lines carry (EMF, see src/log.mjs), AWS/Lambda, AWS/DynamoDB and
# AWS/CloudFront (us-east-1; the distribution in front of both backends).
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
NAME="foreignmenu-api"
LOG_GROUP="/aws/lambda/${NAME}"
DISTRIBUTION_ID="${DISTRIBUTION_ID:-E3DRAQW0VRAYMG}"  # api.chuanbei.dev
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
HERE="$(cd "$(dirname "$0")" && pwd)"
aws() { command aws --region "${REGION}" "$@"; }

echo "== Log retention (${LOG_RETENTION_DAYS} days)"
# 30 days: enough to debug; the privacy policy promises no period, and purchases / ledger live in DynamoDB.
aws logs create-log-group --log-group-name "${LOG_GROUP}" >/dev/null 2>&1 || true
aws logs put-retention-policy --log-group-name "${LOG_GROUP}" --retention-in-days "${LOG_RETENTION_DAYS}"

echo "== Log metric filter"
# ERROR lines that are not request lines (settlement / ledger / purchase-record failures, gave-up retries):
# they never reach a client as a 5xx, so the request metrics can't see them.
aws logs put-metric-filter --log-group-name "${LOG_GROUP}" --filter-name error-events \
  --filter-pattern '{ $.level = "ERROR" && $.msg != "request" }' \
  --metric-transformations metricName=ErrorEvents,metricNamespace=ForeignMenu,metricValue=1,unit=Count

save_query() {  # name, query — update in place if it already exists; prints the id
  local id
  id="$(aws logs describe-query-definitions --query-definition-name-prefix "$1" \
        --query "queryDefinitions[?name=='$1'].queryDefinitionId | [0]" --output text)"
  if [[ "${id}" == "None" || -z "${id}" ]]; then
    aws logs put-query-definition --name "$1" --log-group-names "${LOG_GROUP}" --query-string "$2" --query queryDefinitionId --output text
  else
    aws logs put-query-definition --query-definition-id "${id}" --name "$1" --log-group-names "${LOG_GROUP}" --query-string "$2" --query queryDefinitionId --output text
  fi
}

echo "== Saved queries"
# "name<TAB>relative seconds<TAB>query": saved under ForeignMenu/ and linked from the dashboard's text widget
# (with that time range). Logs Insights doesn't save a time range with a query.
QUERIES="$(mktemp)" LINKS="$(mktemp)" DASH_PY="$(mktemp)"
trap 'rm -f "${QUERIES}" "${LINKS}" "${DASH_PY}"' EXIT
cat >"${QUERIES}" <<'Q'
recent requests	3600	filter msg = "request" | fields @timestamp, route, status, ms, accountKind, userId, model, creditsCharged, costUsd, error | sort @timestamp desc | limit 100
errors (last hour)	3600	filter level = "ERROR" or level = "WARN" | fields @timestamp, msg, route, status, requestId, userId, error, ref, reason | sort @timestamp desc | limit 200
slow requests	86400	filter msg = "request" and ms > 60000 | fields @timestamp, route, status, ms, ttfbMs, model, provider, images, upstreamStatus, finishReason, requestId | sort ms desc | limit 100
one account (edit the id)	604800	filter userId = "anon:REPLACE_ME" or from = "anon:REPLACE_ME" | fields @timestamp, msg, route, status, ms, creditsCharged, creditsCovered, creditsLeft, grant, linked, productId, error | sort @timestamp desc | limit 500
one request (edit the id)	86400	filter requestId = "REPLACE_ME" | fields @timestamp, level, msg, route, status, ms, error | sort @timestamp asc
AI upstream failures	86400	filter msg = "request" and ispresent(upstreamError) | fields @timestamp, route, model, provider, upstreamError, upstreamStatus, error, storefront, requestId | sort @timestamp desc | limit 200
cost and credits (pick a time range)	604800	filter msg = "request" and costUsd > 0 | stats sum(costUsd) as usd, sum(creditsCharged) as credits, sum(creditsCovered) as covered, count(*) as calls, count_distinct(userId) as users by route, model
cost by model per day	2592000	filter msg = "request" and costUsd > 0 | stats sum(costUsd) as usd, sum(creditsCharged) as credits, sum(creditsCovered) as covered, count(*) as calls by bin(1d), model | sort bin(1d) desc
menu latency percentiles	86400	filter msg = "request" and route = "POST /menu" and status = 200 | stats count(*) as n, pct(ttfbMs, 50) as ttfbP50, pct(ms, 50) as p50, pct(ms, 95) as p95, pct(ms, 99) as p99 by bin(1h), provider
purchases	2592000	filter msg in ["purchase", "purchase rejected", "subscription", "subscription rejected"] | fields @timestamp, msg, userId, productId, credits, credited, offerType, offerIdentifier, price, currency, storefront, environment, reason | sort @timestamp desc | limit 200
subscription notifications	2592000	filter msg = "app store notification" or msg like /notification/ | fields @timestamp, msg, type, subtype, ignored, active, expiresAt, userId, productId, price, currency, reason | sort @timestamp desc | limit 200
notifications by type and outcome	2592000	filter msg = "app store notification" | stats count(*) as n by type, ignored | sort n desc
merges (Sign in with Apple link)	2592000	filter msg = "device account linked" or (msg = "request" and route = "POST /auth/apple/link") | fields @timestamp, msg, status, linked, userId, from, creditsMoved, error, reason | sort @timestamp desc | limit 200
rate-limit hits (anonymous signups, 429)	604800	filter msg = "request" and route = "POST /auth/anonymous" and status = 429 | stats count(*) as hits by bin(1h) | sort bin(1h) desc
device accounts created	2592000	filter msg = "device account created" | stats count(*) as accounts, sum(signupCredits) as credits, count(predecessor) as again_without_bonus by bin(1d)
region refusals (403)	604800	filter msg = "request" and region = 1 | stats count(*) as n by route, storefront
out of credits (402)	604800	filter msg = "request" and status = 402 | stats count(*) as refusals by userId | sort refusals desc
contention and retries	604800	filter msg like /contention|gave up|retry/ or (msg = "request" and ddbRetries > 0) | fields @timestamp, msg, route, ddbRetries, ddbConditionalFailures, retries, requestId | sort @timestamp desc | limit 200
Q
while IFS=$'\t' read -r qname secs query; do
  id="$(save_query "ForeignMenu/${qname}" "${query}")"
  printf '%s\t%s\t%s\t%s\n' "${qname}" "${secs}" "${id}" "${query}" >>"${LINKS}"
done <"${QUERIES}"
# Renamed in this version: the old name would otherwise linger next to the new one.
for old in "ForeignMenu/errors"; do
  id="$(aws logs describe-query-definitions --query-definition-name-prefix "${old}" --query "queryDefinitions[?name=='${old}'].queryDefinitionId | [0]" --output text)"
  [[ "${id}" != "None" && -n "${id}" ]] && aws logs delete-query-definition --query-definition-id "${id}" >/dev/null
done

# Alarms first: the dashboard's alarm widget lists them.
"${HERE}/alarms.sh"

echo "== Dashboard"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
# The generator goes through a file: bash 3.2 (macOS) misreads quotes in a heredoc inside $( ).
cat >"${DASH_PY}" <<'PY'
import json, sys
from urllib.parse import quote
region, log_group, fn, distribution, links_file, account = sys.argv[1:7]
ns = "ForeignMenu"

def metric(name, stat="Sum", route=None, label=None):
    m = [ns, name] + (["route", route] if route else [])
    return m + [{"stat": stat, "label": label or (f"{route} " if route else "") + name}]
def search(expr, stat, label=None, period=300):
    return [[{"expression": f"SEARCH('{expr}', '{stat}', {period})"} | ({"label": label} if label else {})]]
def widget(title, metrics, x, y, w=12, h=6, view="timeSeries", stacked=False, period=300, region_=None):
    for i, m in enumerate(metrics):  # expressions need an id, unique within the widget
        if isinstance(m[0], dict): m[0].setdefault("id", f"e{i}")
    return {"type": "metric", "x": x, "y": y, "width": w, "height": h,
            "properties": {"title": title, "region": region_ or region, "view": view, "stacked": stacked, "period": period, "metrics": metrics}}
def logs(title, query, x, y, w, h, view="table"):
    return {"type": "log", "x": x, "y": y, "width": w, "height": h,
            "properties": {"title": title, "region": region, "view": view, "query": f"SOURCE '{log_group}' | {query}"}}
def text(md, x, y, w=24, h=1):
    return {"type": "text", "x": x, "y": y, "width": w, "height": h, "properties": {"markdown": md}}

# Links to the saved queries, opened in Logs Insights with their time range.
def esc(s):  # the console's URL state: percent-encoding with "*" for "%"
    return quote(s, safe="").replace("~", "%7E").replace("%", "*")
def insights(query, secs):
    state = f"~(end~0~start~-{secs}~timeType~'RELATIVE~unit~'seconds~editorString~'{esc(query)}~source~(~'{esc(log_group)}))"
    return f"https://{region}.console.aws.amazon.com/cloudwatch/home?region={region}#logsV2:logs-insights$3FqueryDetail$3D{state}"
rows = [l.rstrip("\n").split("\t", 3) for l in open(links_file) if l.strip()]
span = lambda s: f"{int(s) // 86400} d" if int(s) >= 86400 else f"{int(s) // 3600} h"
console = f"https://{region}.console.aws.amazon.com/cloudwatch/home?region={region}"
md = ("### 外乡人的菜单 / ForeignMenu backend · runbook\n"
      "**Saved queries** (Logs Insights → Saved queries → ForeignMenu/; each link opens it with its time range): "
      + " · ".join(f"[{name}]({insights(q, secs)}) ({span(secs)})" for name, secs, _id, q in rows)
      + f"\n\n**Alarms** → [all alarms]({console}#alarmsV2:?search=ForeignMenu) (SNS topic `chuanbei-ops-alerts`; the CloudFront alarm is "
      "`chuanbei-cloudfront-5xx-rate` in us-east-1, set up by the DateSeries repo) · never logged: menu photos or text, prompts, answers, tokens, secrets.")

y = 0
W = [text(md, 0, y, h=3)]; y += 3
# Money first: what the models cost us, and what was charged (1 credit = US$0.005 at list price).
calls = 'filter msg = "request" and costUsd > 0'
W += [
    logs("模型花费（美元）与扣掉的分 · 所选时间段",
         f"{calls} | stats sum(costUsd) as model_usd, sum(creditsCharged) as credits, sum(creditsCharged) * 0.005 as credits_usd,"
         " sum(creditsCovered) as covered, count(*) as calls, count_distinct(userId) as users", 0, y, 16, 3),
    logs("按接口和模型", f"{calls} | stats sum(costUsd) as usd, sum(creditsCharged) as credits, count(*) as calls by route, model | sort usd desc",
         16, y, 8, 3),
]
y += 3
W += [
    logs("每天：模型花费（美元）", f"{calls} | stats sum(costUsd) as usd by bin(1d)", 0, y, 12, 7, view="bar"),
    logs("用得最多的 10 个用户", f"{calls} | stats sum(costUsd) as usd, sum(creditsCharged) as credits, count(*) as calls by userId"
         " | sort usd desc | limit 10", 12, y, 12, 7),
]
y += 7

W += [text("## Traffic, errors, latency", 0, y)]; y += 1
W += [
    widget("Requests by route", search(f"{{{ns},route}} MetricName=\"Requests\"", "Sum"), 0, y),
    widget("5xx by route; 4xx (402 out of credits, 403 region, 410 retired redeem, 429 signup limit)",
           search(f"{{{ns},route}} MetricName=\"ServerErrors\"", "Sum")
           + [metric("ClientErrors", label="4xx (all routes)"), metric("RegionRefusals", label="403 region"),
              metric("RedeemGone", label="410 redeem (old builds)"), metric("AnonRateLimited", label="429 anonymous signup limit")], 12, y),
]
y += 6
W += [
    widget("Menu page latency (ms): p50 / p95 / p99", [metric("LatencyMs", "p50", "POST /menu", "p50"), metric("LatencyMs", "p95", "POST /menu", "p95"),
           metric("LatencyMs", "p99", "POST /menu", "p99"), metric("TimeToFirstByteMs", "p50", "POST /menu", "first byte p50")], 0, y, w=8),
    widget("Dish picture latency (ms): p50 / p95 / p99", [metric("LatencyMs", "p50", "POST /image", "p50"), metric("LatencyMs", "p95", "POST /image", "p95"),
           metric("LatencyMs", "p99", "POST /image", "p99")], 8, y, w=8),
    widget("Requests by account kind (anon = device account)", search(f"{{{ns},accountKind}} MetricName=\"Requests\"", "Sum"), 16, y, w=8),
]
y += 6

W += [text("## AI models (OpenAI; Bedrock Mistral where OpenAI isn't offered, e.g. HK/MO)", 0, y)]; y += 1
W += [
    widget("AI cost per day by model (US$, incl. dish pictures)", search(f"{{{ns},model}} MetricName=\"CostUsd\"", "Sum", period=86400),
           0, y, w=8, view="bar", stacked=True, period=86400),
    widget("Model calls and upstream errors by provider", search(f"{{{ns},provider}} MetricName=\"ModelCalls\"", "Sum", "calls")
           + search(f"{{{ns},provider}} MetricName=\"ModelErrors\"", "Sum", "errors"), 8, y, w=8),
    widget("Latency p95 by model (ms)", search(f"{{{ns},model}} MetricName=\"LatencyMs\"", "p95"), 16, y, w=8),
]
y += 6
W += [
    widget("Tokens", [metric("InputTokens", route="POST /menu"), metric("OutputTokens", route="POST /menu"),
                      metric("InputTokens", route="POST /image"), metric("OutputTokens", route="POST /image")], 0, y),
    widget("AI cost per hour (US$, all models)", [metric("CostUsd", label="US$")], 12, y, period=3600),
]
y += 6

W += [text("## Accounts, purchases, membership, credits", 0, y)]; y += 1
W += [
    widget("Signups per day: Apple vs device (anon); device accounts again without the bonus",
           search(f"{{{ns},accountKind}} MetricName=\"Signups\"", "Sum", period=86400)
           + [metric("SignupsWithoutBonus", label="device again, no bonus"), metric("AnonRateLimited", label="429 signup limit")],
           0, y, w=8, view="bar", period=86400),
    widget("Sign in with Apple link: attach / merge / already / switch", search(f"{{{ns},linked}} MetricName=\"AccountLinks\"", "Sum", period=3600)
           + [metric("CreditsMoved", label="credits moved")], 8, y, w=8, period=3600),
    widget("Purchases per day by product (offer codes apart)", search(f"{{{ns},productId}} MetricName=\"Purchases\"", "Sum", period=86400)
           + [metric("OfferRedemptions", label="offer code redemptions"), metric("PurchaseRejections", label="rejected")],
           16, y, w=8, view="bar", period=86400),
]
y += 6
W += [
    widget("Revenue per day by currency (before Apple's cut)", search(f"{{{ns},currency}} MetricName=\"Revenue\"", "Sum", period=86400),
           0, y, w=8, view="bar", stacked=True, period=86400),
    widget("Membership: updates (active / inactive), notifications by type",
           search(f"{{{ns},subStatus}} MetricName=\"SubscriptionUpdates\"", "Sum", "status")
           + search(f"{{{ns},notificationType}} MetricName=\"StoreNotifications\"", "Sum", "type"), 8, y, w=8, period=3600),
    widget("Store notifications by outcome (error = failed on our side, still answered 200)",
           search(f"{{{ns},outcome}} MetricName=\"StoreNotifications\"", "Sum"), 16, y, w=8, period=3600),
]
y += 6
W += [
    widget("Credits economy per day: charged vs covered vs granted vs bought",
           [metric("CreditsCharged", label="charged (balance)"), metric("CreditsCovered", label="covered (membership)"),
            metric("CreditsGranted", label="granted (signup + subscriber)"), metric("CreditsPurchased", label="bought"),
            metric("OverFairUse", label="calls past fair use")], 0, y, w=8, view="bar", period=86400),
    widget("Subscriber and monthly grants", [metric("SubscriberGrants"), metric("MonthlyGrants")], 8, y, w=8, period=3600),
    widget("Apple token revocation / code exchange (needs secret foreignmenu/siwa-key)",
           [metric("AppleRevokeSkipped", label="revoke skipped (no key)"), metric("AppleRevokeFailed", label="revoke failed"),
            metric("AppleTokenSkipped", label="code exchange skipped"), metric("AppleTokenFailed", label="code exchange failed")]
           + search(f"{{{ns},rejectReason}} MetricName=\"PurchaseRejections\"", "Sum", "rejected"), 16, y, w=8, period=3600),
]
y += 6

# The Lambda itself. No reserved concurrency: the account pool (1000) is shared with DateSeries.
def lam(name, stat="Sum", label=None):
    return ["AWS/Lambda", name, "FunctionName", fn, {"stat": stat, "label": label or name}]
W += [text("## Lambda, DynamoDB, CloudFront", 0, y)]; y += 1
W += [
    widget("Lambda: invocations, errors, throttles", [lam("Invocations"), lam("Errors"), lam("Throttles"),
           metric("ErrorEvents", label="ERROR log events (settlement, ledger…)")], 0, y, w=8),
    widget("Lambda: concurrency (account pool 1000, shared with DateSeries; a big scan uses several)",
           [lam("ConcurrentExecutions", "Maximum", "foreignmenu-api (max)"),
            ["AWS/Lambda", "ConcurrentExecutions", {"stat": "Maximum", "label": "whole account (max)"}]], 8, y, w=8),
    widget("Lambda duration (ms)", [lam("Duration", "p50", "p50"), lam("Duration", "p95", "p95"), lam("Duration", "Maximum", "max")], 16, y, w=8),
]
y += 6
tables = ["foreignmenu-accounts", "foreignmenu-ledger", "foreignmenu-promo", "foreignmenu-usage-daily", "foreignmenu-purchases"]
def ddb(name, table, stat="Sum"):
    return ["AWS/DynamoDB", name, "TableName", table, {"stat": stat, "label": f"{table.replace('foreignmenu-', '')} {name}"}]
W += [
    widget("DynamoDB consumed capacity", [ddb(n, t) for t in tables for n in ["ConsumedReadCapacityUnits", "ConsumedWriteCapacityUnits"]], 0, y, w=8),
    widget("DynamoDB throttles & errors", [ddb(n, t) for t in tables for n in ["ReadThrottleEvents", "WriteThrottleEvents"]]
           + [ddb("SystemErrors", t) for t in tables], 8, y, w=8),
    widget("DynamoDB work per request (from our logs)",
           [metric("DdbCalls", "Average", "POST /menu", "/menu calls per request"), metric("DdbMs", "Average", "POST /menu", "/menu DynamoDB ms"),
            metric("DdbConditionalFailures", label="conditional failures"), metric("DdbRetries", label="optimistic-locking retries"),
            metric("DdbErrors", label="DynamoDB errors")], 16, y, w=8),
]
y += 6
cf = lambda name, stat, label: ["AWS/CloudFront", name, "DistributionId", distribution, "Region", "Global", {"stat": stat, "label": label, "region": "us-east-1"}]
W += [
    widget(f"CloudFront api.chuanbei.dev ({distribution}, both apps): requests", [cf("Requests", "Sum", "requests")], 0, y, region_="us-east-1"),
    widget("CloudFront error rate (%)", [cf("4xxErrorRate", "Average", "4xx %"), cf("5xxErrorRate", "Average", "5xx %")], 12, y, region_="us-east-1"),
]
y += 6

# Revenue: the "purchase" lines (price in the customer's currency, before Apple's commission).
buys = 'filter msg = "purchase" and credited = 1'
W += [text("## Revenue and purchases (logs)", 0, y)]; y += 1
W += [
    logs("收入（Apple 抽成前）· 按币种和环境", f"{buys} | stats count(*) as purchases, sum(price) as gross, sum(credits) as credits"
         " by currency, environment | sort environment, gross desc", 0, y, 12, 5),
    logs("每天购买次数（正式环境）", f'{buys} and environment = "Production" | stats count(*) as purchases by bin(1d)', 12, y, 12, 5, view="bar"),
]
y += 5
W += [
    logs("按商品和地区（含优惠码）", f"{buys} | stats count(*) as purchases, sum(price) as gross, count(offerType) as offer_codes by productId, storefront, currency"
         " | sort purchases desc", 0, y, 12, 6),
    logs("被拒的购买（查「付了钱没到账」）", 'filter msg in ["purchase rejected", "subscription rejected"] | stats count(*) as n by msg, reason', 12, y, 12, 6),
]
y += 6
W += [{"type": "alarm", "x": 0, "y": y, "width": 24, "height": 3,
       "properties": {"title": "Alarms", "alarms": [f"arn:aws:cloudwatch:{region}:{account}:alarm:ForeignMenu-{a}" for a in
                      ["5xx-rate", "lambda-errors", "lambda-throttles", "menu-p95-latency", "image-p95-latency", "ai-upstream-errors",
                       "ai-cost-daily", "dynamodb-throttles", "store-notification-failures", "error-events", "anon-signup-limit"]]}}]
print(json.dumps({"start": "-P7D", "widgets": W}))
PY
DASH="$(python3 "${DASH_PY}" "${REGION}" "${LOG_GROUP}" "${NAME}" "${DISTRIBUTION_ID}" "${LINKS}" "${ACCOUNT_ID}")"
aws cloudwatch put-dashboard --dashboard-name ForeignMenu --dashboard-body "${DASH}" --query 'DashboardValidationMessages' --output text

echo "Dashboard: https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards/dashboard/ForeignMenu"
