// Structured logging. One JSON object per line on stdout, so CloudWatch Logs Insights can query
// every field directly. Request lines also carry CloudWatch Embedded Metric Format (EMF) metadata:
// CloudWatch turns them into metrics in the "ForeignMenu" namespace without any API calls.
//
// Privacy: never log menu text, photos, prompts, model output, tokens or secrets. Only metadata.

import { requestScope } from "./ddbstats.mjs";

const NAMESPACE = "ForeignMenu";

function emit(line) {
  // Written raw (not console.log) so each line stays pure JSON, which EMF requires.
  process.stdout.write(`${JSON.stringify(line)}\n`);
}

/** Non-request events: grants, settlement problems, unexpected errors. Lines inside a request carry its id. */
export function logEvent(level, msg, fields = {}) {
  const requestId = fields.requestId ?? requestScope.getStore()?.requestId;
  emit({ time: new Date().toISOString(), level, msg, ...(requestId ? { requestId } : {}), ...fields });
}

/** "anon" | "apple" | "dev" | "none" (no signed-in user) | "other": a metric dimension, never the id itself. */
export function accountKind(userId) {
  if (typeof userId !== "string" || !userId) return "none";
  const kind = userId.split(":")[0];
  return ["anon", "apple", "dev"].includes(kind) ? kind : "other";
}

/** Values that become metric dimensions: a fixed vocabulary, anything else is "other". */
const vocabulary = (allowed) => (v) => (allowed.includes(v) ? v : "other");
const notificationType = (t) => (typeof t === "string" && /^[A-Z_]{3,40}$/.test(t) ? t : "none");
const productDim = (p) => (typeof p === "string" && /^ai\.xiangyang\.MenuLens\.[A-Za-z0-9.]{1,40}$/.test(p) ? p : "other");
const currencyDim = (c) => (typeof c === "string" && /^[A-Z]{3}$/.test(c) ? c : "other");
/** Our own reasons are snake_case; anything else (an exception's message) is an error. */
const reasonDim = (r) => (typeof r === "string" && /^[a-z_]{1,32}$/.test(r) ? r : "error");

/**
 * The single summary line for one HTTP request, plus metrics.
 * Fields: requestId, route, status, ms, accountKind, userId?, error?, ddb* (calls, time, capacity, conditional
 * failures, errors, optimistic-locking retries, ops per command), and for /menu and /image: model (our id), provider,
 * upstreamError? ("network" | "status"), storefront?, costUsd, ttfbMs, inputTokens, cachedTokens, outputTokens,
 * creditsCharged, creditsReserved, creditsLeft (credits with one decimal), creditsCovered / covered? / overFairUse?
 * (subscribers), upstreamStatus, grant? + creditsGranted?, images?/inputChars? (counts only); accounts: linked?
 * ("attach" | "merge" | "already" | "switch") + creditsMoved?, from? (the device account), rateLimited?, region?;
 * purchases and subscriptions: productId, price, currency, offer?, creditsPurchased, newSubscription?, rejectReason?,
 * subActive?; App Store notifications: notification (type), subtype?, outcome; Apple: appleRevoke?, appleToken?
 *
 * Metrics (namespace ForeignMenu), all low-cardinality: per route and in total; Requests/Signups per accountKind;
 * model calls per model and per provider; purchases per productId; revenue per currency; store notifications per
 * type and per outcome; account links per kind; purchase rejections per reason.
 */
export function logRequest(r) {
  const status = r.status ?? 500;
  const kind = r.accountKind ?? accountKind(r.userId);
  const metrics = {
    Requests: 1,
    ServerErrors: status >= 500 ? 1 : 0,
    ClientErrors: status >= 400 && status < 500 ? 1 : 0,
    LatencyMs: r.ms,
  };
  // Usage metrics only exist for model calls; leaving them out elsewhere keeps averages honest.
  if (typeof r.inputTokens === "number") {
    Object.assign(metrics, { InputTokens: r.inputTokens, CachedTokens: r.cachedTokens ?? 0, OutputTokens: r.outputTokens });
  }
  if (typeof r.costUsd === "number") metrics.CostUsd = r.costUsd;
  // A call that reached (or tried to reach) a model provider; upstreamError says it failed there.
  if (r.provider) Object.assign(metrics, { ModelCalls: 1, ModelErrors: r.upstreamError ? 1 : 0 });
  if (typeof r.creditsCharged === "number") metrics.CreditsCharged = r.creditsCharged;
  // What subscriptions covered instead of charging (fair-use usage), and calls past the fair use.
  if (typeof r.creditsCovered === "number" && r.creditsCovered > 0) metrics.CreditsCovered = r.creditsCovered;
  if (r.overFairUse) metrics.OverFairUse = 1;
  if (typeof r.ttfbMs === "number") metrics.TimeToFirstByteMs = r.ttfbMs;
  if (r.grant) metrics[{ signup: "Signups", subscriber: "SubscriberGrants", none: "SignupsWithoutBonus" }[r.grant] ?? "MonthlyGrants"] = 1;
  if (typeof r.creditsGranted === "number" && r.creditsGranted > 0) metrics.CreditsGranted = r.creditsGranted;
  if (r.notification !== undefined || r.route === "POST /appstore/notifications") metrics.StoreNotifications = 1;
  if (r.rateLimited) metrics.AnonRateLimited = 1;
  if (r.region) metrics.RegionRefusals = 1;
  if (status === 410) metrics.RedeemGone = 1; // old builds still calling the retired redeem codes
  if (typeof r.creditsMoved === "number" && r.creditsMoved > 0) metrics.CreditsMoved = r.creditsMoved;
  if (r.appleRevoke === "no_key") metrics.AppleRevokeSkipped = 1;
  if (r.appleRevoke === "failed") metrics.AppleRevokeFailed = 1;
  if (r.appleToken === "no_key") metrics.AppleTokenSkipped = 1;
  if (r.appleToken === "failed") metrics.AppleTokenFailed = 1;
  if (typeof r.ddbCalls === "number") {
    Object.assign(metrics, { DdbCalls: r.ddbCalls, DdbMs: r.ddbMs, DdbCapacityUnits: r.ddbCapacityUnits,
                             DdbConditionalFailures: r.ddbConditionalFailures, DdbErrors: r.ddbErrors, DdbRetries: r.ddbRetries ?? 0 });
  }

  // Further metric groups, each with its own dimensions. A group's dimension values are root fields of the line.
  const groups = [[[["route"], []], metrics],
    [[["accountKind"]], { Requests: 1, ...pick(metrics, ["Signups", "SignupsWithoutBonus"]) }]];
  const dims = { accountKind: kind };
  if (r.provider) {
    Object.assign(dims, { provider: r.provider === "bedrock" ? "bedrock" : "openai", model: String(r.model ?? "unknown").slice(0, 40) });
    groups.push([[["model"], ["provider"]], {
      LatencyMs: r.ms, ...pick(metrics, ["ModelCalls", "ModelErrors", "CostUsd", "InputTokens", "OutputTokens", "TimeToFirstByteMs"]),
    }]);
  }
  if (r.linked) {
    dims.linked = vocabulary(["attach", "merge", "already", "switch"])(r.linked);
    groups.push([[["linked"]], { AccountLinks: 1 }]);
  }
  if (r.productId && (typeof r.creditsPurchased === "number" || r.newSubscription)) {
    dims.productId = productDim(r.productId);
    groups.push([[["productId"], []], {
      Purchases: 1, ...(r.offer ? { OfferRedemptions: 1 } : {}),
      ...(typeof r.creditsPurchased === "number" ? { CreditsPurchased: r.creditsPurchased } : {}),
    }]);
    if (typeof r.price === "number" && r.currency) {
      dims.currency = currencyDim(r.currency);
      groups.push([[["currency"]], { Revenue: r.price }]); // the customer's currency, before Apple's commission
    }
  }
  if (r.rejectReason) {
    dims.rejectReason = reasonDim(r.rejectReason);
    groups.push([[["rejectReason"]], { PurchaseRejections: 1 }]);
  }
  if (metrics.StoreNotifications) {
    // Notifications always answer 200; "error" is one that failed on our side (logged as "notification not applied").
    Object.assign(dims, { notificationType: notificationType(r.notification),
      outcome: status >= 500 ? "error" : r.ignored ? reasonDim(r.ignored) : r.notification ? "applied" : "error" });
    groups.push([[["notificationType"], ["outcome"]], { StoreNotifications: 1 }]);
  }
  if (typeof r.subActive === "boolean") {
    dims.subStatus = r.subActive ? "active" : "inactive";
    groups.push([[["subStatus"]], { SubscriptionUpdates: 1 }]);
  }

  const values = Object.assign({}, ...groups.map(([, m]) => m));
  const units = { LatencyMs: "Milliseconds", TimeToFirstByteMs: "Milliseconds", DdbMs: "Milliseconds" };
  emit({
    time: new Date().toISOString(),
    level: status >= 500 ? "ERROR" : status >= 400 ? "WARN" : "INFO",
    msg: "request",
    ...r,
    status,
    ...dims,
    ...values,
    _aws: {
      Timestamp: Date.now(),
      CloudWatchMetrics: groups.map(([Dimensions, m]) => ({
        Namespace: NAMESPACE,
        Dimensions, // e.g. per route, and an all-routes total
        Metrics: Object.keys(m).map((Name) => ({ Name, Unit: units[Name] ?? "Count" })),
      })),
    },
  });
}

function pick(o, keys) {
  return Object.fromEntries(keys.filter((k) => o[k] !== undefined).map((k) => [k, o[k]]));
}
