// The request line's CloudWatch Embedded Metric Format: every dimension a metric group names is a
// root field of the line (CloudWatch drops the metrics otherwise), and dimension values stay a small
// fixed vocabulary (never user ids, never free text).
import assert from "node:assert/strict";
import { test } from "node:test";
import { accountKind, logEvent, logRequest } from "../src/log.mjs";
import { newScope, requestScope } from "../src/ddbstats.mjs";

function capture(fn) {
  const lines = [];
  const write = process.stdout.write;
  process.stdout.write = (chunk) => { lines.push(JSON.parse(String(chunk))); return true; };
  try { fn(); } finally { process.stdout.write = write; }
  return lines;
}

/** { "dim1,dim2": { metricName: value } } for one line. */
function metricsOf(line) {
  const out = {};
  for (const d of line._aws.CloudWatchMetrics) {
    for (const dims of d.Dimensions) {
      for (const k of dims) assert.ok(typeof line[k] === "string", `dimension ${k} must be a root string`);
      const key = dims.join(",");
      out[key] ??= {};
      for (const { Name } of d.Metrics) {
        assert.equal(typeof line[Name], "number", `metric ${Name} must be a root number`);
        out[key][Name] = line[Name];
      }
    }
  }
  return out;
}

test("account kind is a fixed vocabulary", () => {
  assert.equal(accountKind("anon:6f1c"), "anon");
  assert.equal(accountKind("apple:000123.abc"), "apple");
  assert.equal(accountKind(undefined), "none");
  assert.equal(accountKind("weird"), "other");
});

test("a /menu line: route totals, account kind and the model groups", () => {
  const [line] = capture(() => logRequest({
    requestId: "r1", route: "POST /menu", status: 200, ms: 30000, userId: "anon:abc", model: "mistral-large-3", provider: "bedrock",
    inputTokens: 3000, cachedTokens: 0, outputTokens: 2000, costUsd: 0.0045, creditsCharged: 0.9, ttfbMs: 2000,
    ddbCalls: 4, ddbMs: 20, ddbCapacityUnits: 3, ddbConditionalFailures: 1, ddbErrors: 0, ddbRetries: 1,
  }));
  const m = metricsOf(line);
  assert.equal(line.accountKind, "anon");
  assert.equal(m.route.CostUsd, 0.0045);
  assert.equal(m[""].DdbRetries, 1);
  assert.deepEqual(m.accountKind, { Requests: 1 });
  assert.equal(m.model.ModelCalls, 1);
  assert.equal(m.provider.ModelErrors, 0);
  assert.ok(!Object.keys(m).some((k) => k.includes("userId")));
});

test("an upstream failure counts as a model error", () => {
  const [line] = capture(() => logRequest({ route: "POST /image", status: 502, ms: 50, userId: "apple:x", model: "gpt-image-1-mini",
    provider: "openai", upstreamError: "status", creditsCharged: 0 }));
  assert.equal(metricsOf(line).model.ModelErrors, 1);
});

test("signups per account kind; a device account without the bonus isn't a monthly grant", () => {
  const [anon] = capture(() => logRequest({ route: "POST /auth/anonymous", status: 200, ms: 20, userId: "anon:a", grant: "signup", creditsGranted: 300 }));
  assert.deepEqual(metricsOf(anon).accountKind, { Requests: 1, Signups: 1 });
  assert.equal(metricsOf(anon).route.CreditsGranted, 300);
  const [again] = capture(() => logRequest({ route: "POST /auth/anonymous", status: 200, ms: 20, userId: "anon:b", grant: "none" }));
  assert.equal(metricsOf(again).route.SignupsWithoutBonus, 1);
  assert.equal(metricsOf(again).route.MonthlyGrants, undefined);
  const [limited] = capture(() => logRequest({ route: "POST /auth/anonymous", status: 429, ms: 5, rateLimited: true }));
  assert.equal(metricsOf(limited).route.AnonRateLimited, 1);
});

test("account links per kind, with the credits moved", () => {
  const [line] = capture(() => logRequest({ route: "POST /auth/apple/link", status: 200, ms: 90, userId: "apple:x", from: "anon:a",
    linked: "merge", creditsMoved: 120.5 }));
  const m = metricsOf(line);
  assert.deepEqual(m.linked, { AccountLinks: 1 });
  assert.equal(m.route.CreditsMoved, 120.5);
});

test("purchases per product (offer codes too) and revenue per currency", () => {
  const [line] = capture(() => logRequest({ route: "POST /purchase", status: 200, ms: 80, userId: "anon:a",
    productId: "ai.xiangyang.MenuLens.credits.500", creditsPurchased: 500, offer: true, price: 0, currency: "HKD" }));
  const m = metricsOf(line);
  assert.deepEqual(m.productId, { Purchases: 1, OfferRedemptions: 1, CreditsPurchased: 500 });
  assert.deepEqual(m.currency, { Revenue: 0 });
});

test("notifications: applied, a known reason, or an error from our side", () => {
  const [applied] = capture(() => logRequest({ route: "POST /appstore/notifications", status: 200, ms: 30, notification: "DID_RENEW",
    subActive: true, productId: "ai.xiangyang.MenuLens.sub.monthly", newSubscription: true, price: 4, currency: "USD" }));
  assert.equal(applied.outcome, "applied");
  assert.deepEqual(metricsOf(applied).subStatus, { SubscriptionUpdates: 1 });
  assert.deepEqual(metricsOf(applied).currency, { Revenue: 4 });
  const [unknown] = capture(() => logRequest({ route: "POST /appstore/notifications", status: 200, ms: 30, notification: "EXPIRED",
    ignored: "unknown_subscription" }));
  assert.equal(unknown.outcome, "unknown_subscription");
  const [failed] = capture(() => logRequest({ route: "POST /appstore/notifications", status: 200, ms: 30, notification: "DID_RENEW",
    ignored: "ProvisionedThroughputExceededException: Rate exceeded" }));
  assert.equal(failed.outcome, "error");
  assert.equal(metricsOf(failed).outcome.StoreNotifications, 1);
});

test("retired redeem codes, region refusals and skipped Apple revocations are counted", () => {
  const [gone] = capture(() => logRequest({ route: "POST /promo/redeem", status: 410, ms: 1 }));
  assert.equal(metricsOf(gone).route.RedeemGone, 1);
  const [region] = capture(() => logRequest({ route: "POST /image", status: 403, ms: 1, userId: "anon:a", region: true }));
  assert.equal(metricsOf(region).route.RegionRefusals, 1);
  const [revoke] = capture(() => logRequest({ route: "DELETE /account", status: 200, ms: 5, userId: "apple:x", appleRevoke: "failed" }));
  assert.equal(metricsOf(revoke)[""].AppleRevokeFailed, 1);
});

test("event lines inside a request carry its id", () => {
  const [line] = capture(() => requestScope.run(newScope("req-7"), () => logEvent("WARN", "credit reserve contention", { retries: 1 })));
  assert.equal(line.requestId, "req-7");
});
