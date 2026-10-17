// Subscriptions: what a transaction / renewal / notification does to the stored state, covered calls
// under the monthly fair use, and the subscriber grant — on the in-memory DynamoDB and the throwaway
// signing chain (fixtures/iap, shaped like Apple's).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createPrivateKey, sign, X509Certificate } from "node:crypto";
import { test } from "node:test";
import { billingPeriod, CreditStore, InsufficientCredits, toCredits } from "../src/credits.mjs";
import { stripPrefix } from "../src/prefix.mjs";
import { accountToken, creditableTransaction, PurchaseError, verifyAppleJWS } from "../src/purchase.mjs";
import {
  handleNotification, mergeSubscription, recordEntitlement, publicSubscription, renewalFacts, SubscriptionConflict, SubscriptionStore,
  subscriptionActive, subscriptionTransaction,
} from "../src/subscription.mjs";
import { FakeDDB } from "./fakeddb.mjs";

const dir = new URL("./fixtures/iap/", import.meta.url);
const pem = (f) => readFileSync(new URL(f, dir), "utf8");
const der = (p) => new X509Certificate(p).raw.toString("base64");
const x5c = [der(pem("leaf.pem")), der(pem("int.pem")), der(pem("root.pem"))];
const leafKey = createPrivateKey(pem("leaf.pk8"));
const verify = (j) => verifyAppleJWS(j, { rootFingerprint: new X509Certificate(pem("root.pem")).fingerprint256 });

function jws(payload) {
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = `${enc({ alg: "ES256", x5c })}.${enc(payload)}`;
  return `${head}.${sign("sha256", Buffer.from(head), { key: leafKey, dsaEncoding: "ieee-p1363" }).toString("base64url")}`;
}

const BUNDLE = "ai.xiangyang.MenuLens";
const MONTHLY = "ai.xiangyang.MenuLens.sub.monthly";
const YEARLY = "ai.xiangyang.MenuLens.sub.yearly";
const userId = "apple:000123.abc";
const now = new Date("2026-11-10T12:00:00Z");
const DAY = 86400000;
const tz = "America/Vancouver";
const period = billingPeriod(now, tz);

/** A transaction payload (JWSTransactionDecodedPayload) for the monthly subscription. */
const tx = (over = {}) => ({
  transactionId: "3000000001", originalTransactionId: "3000000001", productId: MONTHLY, type: "Auto-Renewable Subscription",
  bundleId: BUNDLE, environment: "Production", appAccountToken: accountToken(userId),
  purchaseDate: now.getTime() - DAY, expiresDate: now.getTime() + 29 * DAY, price: 4000, currency: "USD", storefront: "USA",
  ...over,
});
const ctx = { userId, bundleId: BUNDLE, allowSandbox: false };

const config = {
  accountsTable: "accounts", ledgerTable: "ledger", promoTable: "promo", dailyTable: "daily",
  monthlyGrant: 0, signupBonus: 300, billingTimeZone: tz, subscriberMonthlyGrant: 50, subscriberMonthlyFairUse: 600,
};
function setup() {
  const ddb = new FakeDDB();
  return { ddb, store: new CreditStore(ddb, config), subs: new SubscriptionStore(ddb, config) };
}
const account = (ddb, id = userId) => ddb.get("accounts", { userId: id });
const ledger = (ddb, id = userId) => [...ddb.table("ledger").values()].filter((e) => e.userId === id).sort((a, b) => (a.at < b.at ? -1 : 1));

/** An opened account with an active monthly subscription, as POST /subscription leaves it. */
async function subscriber(over = {}) {
  const s = setup();
  await s.store.grantIfDue(userId, now);
  await s.subs.link(userId, "3000000001", now);
  await s.subs.apply(userId, subscriptionTransaction(tx(over), ctx), now);
  return s;
}

// --- Transactions --------------------------------------------------------------------------

test("a subscription transaction is checked like a purchase and keeps its expiry", () => {
  assert.deepEqual(subscriptionTransaction(verify(jws(tx())), ctx), {
    productId: MONTHLY, transactionId: "3000000001", originalTransactionId: "3000000001",
    expiresAt: new Date(now.getTime() + 29 * DAY).toISOString(), environment: "Production",
  });
  const bad = (over, c = ctx) => () => subscriptionTransaction(tx(over), c);
  assert.throws(bad({ bundleId: "com.other" }), (e) => e.reason === "wrong_app");
  assert.throws(bad({ productId: "ai.xiangyang.MenuLens.credits.100" }), (e) => e.reason === "unknown_product");
  assert.throws(bad({ type: "Consumable" }), (e) => e.reason === "unknown_product");
  assert.throws(bad({ environment: "Sandbox" }), (e) => e.reason === "wrong_environment");
  assert.equal(bad({ environment: "Sandbox" }, { ...ctx, allowSandbox: true })().environment, "Sandbox");
  assert.throws(bad({ appAccountToken: accountToken("apple:someone-else") }), (e) => e.reason === "wrong_account");
  assert.throws(bad({ expiresDate: undefined }), (e) => e.reason === "bad_jws");
  // …and a subscription is not a credit pack.
  assert.throws(() => creditableTransaction(tx(), ctx), (e) => e instanceof PurchaseError && e.reason === "unknown_product");
});

test("active until expiry, or the end of a billing grace period; never once revoked", () => {
  const sub = { expiresAt: new Date(now.getTime() + DAY).toISOString() };
  assert.equal(subscriptionActive(sub, now), true);
  assert.equal(subscriptionActive(sub, new Date(now.getTime() + 2 * DAY)), false);
  assert.equal(subscriptionActive({ ...sub, graceExpiresAt: new Date(now.getTime() + 5 * DAY).toISOString() }, new Date(now.getTime() + 2 * DAY)), true);
  assert.equal(subscriptionActive({ ...sub, revokedAt: now.toISOString() }, now), false);
  assert.equal(subscriptionActive(undefined, now), false);
});

// --- Merging -------------------------------------------------------------------------------

test("merge: renewals extend, a late older transaction never shortens", () => {
  const first = subscriptionTransaction(tx(), ctx);
  const renewed = subscriptionTransaction(tx({ transactionId: "3000000002", expiresDate: now.getTime() + 59 * DAY }), ctx);
  let s = mergeSubscription(undefined, first, now);
  s = mergeSubscription(s, renewed, now);
  assert.equal(s.transactionId, "3000000002");
  s = mergeSubscription(s, first, now); // the first purchase's notification arriving late
  assert.equal(s.transactionId, "3000000002");
  assert.equal(s.expiresAt, renewed.expiresAt);
  // Upgrading to yearly: a new transaction that runs longer.
  s = mergeSubscription(s, subscriptionTransaction(tx({ transactionId: "3000000003", productId: YEARLY, expiresDate: now.getTime() + 365 * DAY }), ctx), now);
  assert.equal(s.productId, YEARLY);
});

test("merge: a refund of the current transaction revokes; resubscribing clears it", () => {
  let s = mergeSubscription(undefined, subscriptionTransaction(tx(), ctx), now);
  s = mergeSubscription(s, subscriptionTransaction(tx({ revocationDate: now.getTime() }), ctx), now);
  assert.equal(subscriptionActive(s, now), false);
  s = mergeSubscription(s, subscriptionTransaction(tx({ transactionId: "3000000009", expiresDate: now.getTime() + 40 * DAY }), ctx), now);
  assert.equal(s.revokedAt, undefined);
  assert.equal(subscriptionActive(s, now), true);
});

test("merge: renewal info sets auto-renew and grace, newer renewal info only", () => {
  let s = mergeSubscription(undefined, subscriptionTransaction(tx({ expiresDate: now.getTime() - DAY }), ctx), now);
  const off = renewalFacts({ originalTransactionId: "3000000001", autoRenewStatus: 0, signedDate: now.getTime() });
  const grace = renewalFacts({ originalTransactionId: "3000000001", autoRenewStatus: 1, signedDate: now.getTime() - 1000,
    gracePeriodExpiresDate: now.getTime() + 6 * DAY });
  s = mergeSubscription(s, { ...subscriptionTransaction(tx({ expiresDate: now.getTime() - DAY }), ctx), renewal: off }, now);
  assert.equal(s.autoRenew, false);
  s = mergeSubscription(s, { ...subscriptionTransaction(tx({ expiresDate: now.getTime() - DAY }), ctx), renewal: grace }, now);
  assert.equal(s.autoRenew, false); // older renewal info: ignored
  const graceNow = renewalFacts({ originalTransactionId: "3000000001", autoRenewStatus: 1, signedDate: now.getTime() + 1000,
    gracePeriodExpiresDate: now.getTime() + 6 * DAY });
  s = mergeSubscription(s, { ...subscriptionTransaction(tx({ expiresDate: now.getTime() - DAY }), ctx), renewal: graceNow }, now);
  assert.equal(subscriptionActive(s, now), true); // billing problem, but in the grace period
  // The renewal goes through: the grace period ends.
  s = mergeSubscription(s, subscriptionTransaction(tx({ transactionId: "3000000002", expiresDate: now.getTime() + 30 * DAY }), ctx), now);
  assert.equal(s.graceExpiresAt, undefined);
});

test("merge: another Apple ID's shorter subscription doesn't replace an active one", () => {
  const s = mergeSubscription(undefined, subscriptionTransaction(tx({ productId: YEARLY, expiresDate: now.getTime() + 300 * DAY }), ctx), now);
  const other = subscriptionTransaction(tx({ transactionId: "9", originalTransactionId: "9" }), ctx);
  assert.equal(mergeSubscription(s, other, now), s);
});

// --- Store ---------------------------------------------------------------------------------

test("one subscription links to one account; the owner is found for notifications", async () => {
  const { subs } = setup();
  await subs.link(userId, "3000000001", now);
  await subs.link(userId, "3000000001", now); // idempotent
  await assert.rejects(subs.link("apple:other", "3000000001", now), SubscriptionConflict);
  assert.equal(await subs.ownerOf("3000000001"), userId);
  assert.equal(await subs.ownerOf("nope"), null);
});

test("apply is idempotent and survives a concurrent change", async () => {
  const { ddb, subs } = await subscriber();
  const before = structuredClone(account(ddb).subscription);
  await subs.apply(userId, subscriptionTransaction(tx(), ctx), now);
  assert.deepEqual(account(ddb).subscription, before);
  let raced = false;
  ddb.before = async (kind, input) => {
    if (!raced && kind === "Update" && input.UpdateExpression.startsWith("SET subscription")) {
      raced = true; // a notification lands between the read and the write
      const a = ddb.get("accounts", { userId });
      ddb.put("accounts", { ...a, subSeq: a.subSeq + 1, subscription: { ...a.subscription, autoRenew: false } }, ["userId"]);
    }
  };
  await subs.apply(userId, subscriptionTransaction(tx({ transactionId: "3000000002", expiresDate: now.getTime() + 59 * DAY }), ctx), now);
  assert.equal(account(ddb).subscription.transactionId, "3000000002");
  assert.equal(account(ddb).subscription.autoRenew, false); // the concurrent change was kept
});

// --- Covered calls -------------------------------------------------------------------------

test("a subscriber's call is covered: the balance doesn't move, the ledger and rollup say what it covered", async () => {
  const { ddb, store } = await subscriber();
  const before = account(ddb).giftTenths;
  const { split } = await store.reserveCovered(userId, 128, "r1", null, now);
  assert.deepEqual(split, { fromGift: 0, fromPaid: 0, covered: 128, period });
  assert.equal(account(ddb).coveredTenths, 128);
  await store.settle(userId, split, 53, "r1");
  assert.equal(account(ddb).giftTenths, before);
  assert.equal(account(ddb).coveredTenths, 53);
  const [hold, settle] = ledger(ddb).slice(-2);
  assert.deepEqual([hold.type, hold.giftTenths, hold.paidTenths, hold.coveredHoldTenths], ["hold", 0, 0, 128]);
  assert.deepEqual([settle.type, settle.chargedTenths, settle.coveredTenths], ["settle", 0, 53]);
  const rows = [...ddb.table("daily").values()];
  assert.equal(rows.reduce((s, r) => s + r.coveredTenths, 0), 53);
  assert.equal(rows.reduce((s, r) => s + r.spentTenths, 0), 0);
  assert.equal(rows.reduce((s, r) => s + r.calls, 0), 1);
  // A failed call gives the whole reservation back.
  const again = (await store.reserveCovered(userId, 100, "r2", null, now)).split;
  await store.settle(userId, again, 0, "r2");
  assert.equal(account(ddb).coveredTenths, 53);
});

test("above the monthly fair use calls are charged from the balance again", async () => {
  const { ddb, store } = await subscriber();
  ddb.put("accounts", { ...account(ddb), coveredPeriod: period, coveredTenths: 5950 }, ["userId"]);
  assert.ok((await store.reserveCovered(userId, 50, "a", null, now)).split); // exactly to 600
  assert.deepEqual(await store.reserveCovered(userId, 1, "b", null, now), { split: null, reason: "fair_use" });
  // Not subscribed at all: charged as usual.
  const plain = setup();
  await plain.store.grantIfDue("apple:plain", now);
  assert.deepEqual(await plain.store.reserveCovered("apple:plain", 10, "c", null, now), { split: null, reason: "inactive" });
});

test("concurrent covered calls can't pass the cap together", async () => {
  const { ddb, store } = await subscriber();
  ddb.put("accounts", { ...account(ddb), coveredPeriod: period, coveredTenths: 5900 }, ["userId"]);
  const results = await Promise.all([1, 2, 3].map((i) => store.reserveCovered(userId, 60, `c${i}`, null, now)));
  assert.equal(results.filter((r) => r.split).length, 1);
  assert.ok(account(ddb).coveredTenths <= 6000);
});

test("the fair-use meter starts again each billing month", async () => {
  const { ddb, store } = await subscriber({ expiresDate: now.getTime() + 60 * DAY });
  ddb.put("accounts", { ...account(ddb), coveredPeriod: "2026-10", coveredTenths: 6000 }, ["userId"]);
  const { split } = await store.reserveCovered(userId, 80, "m", null, now);
  assert.equal(split.period, period);
  assert.deepEqual([account(ddb).coveredPeriod, account(ddb).coveredTenths], [period, 80]);
});

test("an expired or refunded subscription covers nothing", async () => {
  const later = new Date(now.getTime() + 31 * DAY);
  const { store, subs } = await subscriber();
  assert.equal((await store.reserveCovered(userId, 10, "e", null, later)).reason, "inactive");
  await subs.apply(userId, subscriptionTransaction(tx({ revocationDate: now.getTime() }), ctx), now);
  assert.equal((await store.reserveCovered(userId, 10, "f", null, now)).reason, "inactive");
  await assert.rejects(store.reserve(userId, 999999, "g"), InsufficientCredits); // and the normal path still guards the balance
});

// --- Subscriber grant ----------------------------------------------------------------------

test("subscribers get 50 credits once per month of use; others nothing", async () => {
  const { ddb, store } = await subscriber({ expiresDate: now.getTime() + 60 * DAY });
  assert.equal(toCredits(account(ddb).giftTenths), 300);
  assert.equal((await store.grantIfDue(userId, now)).kind, "subscriber");
  assert.equal(toCredits(account(ddb).giftTenths), 350);
  assert.equal((await store.grantIfDue(userId, now)).kind, null);
  assert.equal(toCredits(account(ddb).giftTenths), 350);
  assert.deepEqual(ledger(ddb).map((e) => e.type), ["signup", "subscriber_grant"]);
  // Next month, still subscribed: again.
  const next = new Date(now.getTime() + 30 * DAY);
  assert.equal((await store.grantIfDue(userId, next)).kind, "subscriber");
  assert.equal(toCredits(account(ddb).giftTenths), 400);
  // After it lapsed: nothing.
  assert.equal((await store.grantIfDue(userId, new Date(now.getTime() + 90 * DAY))).kind, null);
  assert.equal(toCredits(account(ddb).giftTenths), 400);
  const plain = setup();
  await plain.store.grantIfDue("apple:plain", now);
  assert.equal((await plain.store.grantIfDue("apple:plain", next)).kind, null);
});

test("GET /credits reports the subscription in whole credits", async () => {
  const { ddb, store } = await subscriber();
  const { split } = await store.reserveCovered(userId, 128, "r", null, now);
  await store.settle(userId, split, 87, "r");
  const p = publicSubscription(account(ddb), { now, period, fairUseCredits: 600 });
  assert.deepEqual(p, {
    active: true, productId: MONTHLY, expiresAt: new Date(now.getTime() + 29 * DAY).toISOString(), autoRenew: null,
    monthUsedCredits: 9, monthFairUseCredits: 600,
  });
  assert.deepEqual(publicSubscription(undefined, { now, period, fairUseCredits: 600 }), {
    active: false, productId: null, expiresAt: null, autoRenew: null, monthUsedCredits: 0, monthFairUseCredits: 600,
  });
  // Last month's counter doesn't show this month.
  assert.equal(publicSubscription({ ...account(ddb), coveredPeriod: "2026-01" }, { now, period, fairUseCredits: 600 }).monthUsedCredits, 0);
});

// --- POST /subscription ---------------------------------------------------------------------

function entitlementDeps(s, recorded = [], user = userId) {
  return {
    userId: user, verify, subs: s.subs, records: { record: async (u, f) => recorded.push({ u, ...f }) },
    grant: async (u) => (await s.store.grantIfDue(u, now)).item, read: (u) => s.store.read(u), bundleId: BUNDLE, allowSandbox: false,
  };
}

test("POST /subscription: a new account subscribes, gets 300 + 50, and sending it again changes nothing", async () => {
  const s = setup();
  const recorded = [];
  const renewalJws = jws({ originalTransactionId: "3000000001", autoRenewStatus: 1, signedDate: now.getTime() });
  const r = await recordEntitlement({ jws: jws(tx()), renewalJws }, entitlementDeps(s, recorded), now);
  assert.equal(r.isNew, true);
  assert.equal(r.item.subscription.autoRenew, true);
  assert.equal(toCredits(r.item.giftTenths), 350);
  assert.deepEqual(recorded.map((x) => [x.type, x.status, x.source, x.price]), [["subscription", "active", "app", 4]]);
  assert.equal(await s.subs.ownerOf("3000000001"), userId);
  // The app sends the entitlement on every launch.
  const again = await recordEntitlement({ jws: jws(tx()) }, entitlementDeps(s, recorded), now);
  assert.equal(again.isNew, false);
  assert.equal(toCredits(again.item.giftTenths), 350);
  assert.equal(recorded.length, 1);
});

test("POST /subscription: another account, a refunded or foreign transaction is refused with its payload", async () => {
  const s = setup();
  await recordEntitlement({ jws: jws(tx()) }, entitlementDeps(s), now);
  // Same Apple subscription, another of our accounts (no account token on the transaction).
  await assert.rejects(recordEntitlement({ jws: jws(tx({ appAccountToken: undefined })) }, entitlementDeps(s, [], "apple:other"), now),
    (e) => e instanceof SubscriptionConflict && e.payload.transactionId === "3000000001");
  await assert.rejects(recordEntitlement({ jws: jws(tx({ appAccountToken: accountToken("apple:other") })) }, entitlementDeps(s), now),
    (e) => e.reason === "wrong_account");
  await assert.rejects(recordEntitlement({ jws: jws(tx({ revocationDate: now.getTime() })) }, entitlementDeps(s), now), (e) => e.reason === "revoked");
  await assert.rejects(recordEntitlement({ jws: "nope" }, entitlementDeps(s), now), (e) => e.reason === "bad_jws" && e.payload === null);
  // A renewal info that doesn't verify is ignored, not fatal.
  const r = await recordEntitlement({ jws: jws(tx()), renewalJws: "x.y.z" }, entitlementDeps(s), now);
  assert.equal(r.isNew, false);
});

// --- Server notifications ------------------------------------------------------------------

function notification(type, { subtype, transaction = tx(), renewal, bundleId = BUNDLE, environment = "Production" } = {}) {
  return { signedPayload: jws({
    notificationType: type, subtype, notificationUUID: `n-${type}`, version: "2.0", signedDate: now.getTime(),
    data: { bundleId, environment, signedTransactionInfo: transaction && jws(transaction), signedRenewalInfo: renewal && jws(renewal) },
  }) };
}

function deps(s, recorded = []) {
  return { verify, subs: s.subs, records: { record: async (u, f) => recorded.push({ u, ...f }) }, bundleId: BUNDLE, allowSandbox: false };
}

test("notifications: renewal, auto-renew off, billing grace, expiry, refund", async () => {
  const s = await subscriber();
  const recorded = [];
  const d = deps(s, recorded);
  const renewed = tx({ transactionId: "3000000002", expiresDate: now.getTime() + 59 * DAY, purchaseDate: now.getTime() });
  let r = await handleNotification(notification("DID_RENEW", { transaction: renewed }), d, now);
  assert.deepEqual([r.type, r.userId, r.active], ["DID_RENEW", userId, true]);
  assert.equal(account(s.ddb).subscription.expiresAt, new Date(now.getTime() + 59 * DAY).toISOString());
  assert.deepEqual(recorded.map((x) => [x.type, x.status, x.transactionId, x.price, x.currency]), [["subscription", "active", "3000000002", 4, "USD"]]);
  // The same notification again (Apple retries): nothing new recorded.
  await handleNotification(notification("DID_RENEW", { transaction: renewed }), d, now);
  assert.equal(recorded.length, 1);

  r = await handleNotification(notification("DID_CHANGE_RENEWAL_STATUS", { subtype: "AUTO_RENEW_DISABLED", transaction: renewed,
    renewal: { originalTransactionId: "3000000001", autoRenewStatus: 0, signedDate: now.getTime() } }), d, now);
  assert.equal(account(s.ddb).subscription.autoRenew, false);
  assert.equal(account(s.ddb).subscription.status, "DID_CHANGE_RENEWAL_STATUS:AUTO_RENEW_DISABLED");

  const later = new Date(now.getTime() + 60 * DAY);
  r = await handleNotification(notification("DID_FAIL_TO_RENEW", { subtype: "GRACE_PERIOD", transaction: renewed,
    renewal: { originalTransactionId: "3000000001", autoRenewStatus: 1, signedDate: later.getTime(), gracePeriodExpiresDate: later.getTime() + 6 * DAY } }), d, later);
  assert.equal(r.active, true);
  r = await handleNotification(notification("EXPIRED", { subtype: "BILLING_RETRY", transaction: renewed,
    renewal: { originalTransactionId: "3000000001", autoRenewStatus: 0, signedDate: later.getTime() + 7 * DAY } }), d, new Date(later.getTime() + 7 * DAY));
  assert.equal(r.active, false);

  r = await handleNotification(notification("REFUND", { transaction: { ...renewed, revocationDate: now.getTime(), revocationReason: 0 } }), d, now);
  assert.equal(account(s.ddb).subscription.revokedAt, now.toISOString());
  assert.equal(r.active, false);
  assert.deepEqual(recorded.at(-1).status, "refunded");
});

test("notifications: SUBSCRIBED and REVOKE; unknown, foreign and forged ones are answered and ignored", async () => {
  const s = await subscriber();
  const d = deps(s);
  const r = await handleNotification(notification("SUBSCRIBED", { subtype: "RESUBSCRIBE" }), d, now);
  assert.equal(r.active, true);
  await handleNotification(notification("REVOKE", { transaction: tx() }), d, now); // Family Sharing: no revocationDate given
  assert.equal(subscriptionActive(account(s.ddb).subscription, now), false);

  const ignored = async (body) => (await handleNotification(body, d, now)).ignored;
  assert.equal(await ignored(notification("DID_RENEW", { transaction: tx({ originalTransactionId: "unknown" }) })), "unknown_subscription");
  assert.equal(await ignored(notification("DID_RENEW", { bundleId: "com.other" })), "wrong_app");
  assert.equal(await ignored(notification("DID_RENEW", { environment: "Sandbox" })), "sandbox");
  assert.equal(await ignored(notification("TEST", { transaction: null })), "no_transaction");
  assert.equal(await ignored(notification("REFUND", { transaction: tx({ productId: "ai.xiangyang.MenuLens.credits.100", type: "Consumable" }) })), "not_a_subscription");
  assert.equal(await ignored({ signedPayload: "a.b.c" }), "bad_jws");
  assert.equal(await ignored({}), "bad_jws");
  // A real chain but a payload signed for another user's account token.
  assert.equal(await ignored(notification("DID_RENEW", { transaction: tx({ appAccountToken: accountToken("apple:x") }) })), "wrong_account");
  // A forged signature: rejected before anything is read.
  const [h, p] = notification("DID_RENEW").signedPayload.split(".");
  assert.equal(await ignored({ signedPayload: `${h}.${p}.${"A".repeat(86)}` }), "bad_signature");
});

test("notifications arrive under /menu behind CloudFront", () => {
  assert.equal(stripPrefix("/menu/appstore/notifications"), "/appstore/notifications");
  assert.equal(stripPrefix("/appstore/notifications"), "/appstore/notifications");
  assert.equal(stripPrefix("/menu/subscription"), "/subscription");
});
