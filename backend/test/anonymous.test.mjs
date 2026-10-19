// Anonymous device accounts and moving one into an Apple account (anonymous.mjs, merge.mjs), on the
// in-memory DynamoDB: creation, renewal with the device secret, the per-IP limit, attach / merge,
// retries and interruptions, and what happens to the device afterwards. Plus App Store Offer Code
// redemptions of credit packs, which arrive as ordinary purchases.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createPrivateKey, sign, X509Certificate } from "node:crypto";
import { test } from "node:test";
import { AnonymousAccounts, clientIp, DeviceAuthError, isAnonymous, RateLimited, secretHash } from "../src/anonymous.mjs";
import { CreditStore, PurchaseConflict, toCredits } from "../src/credits.mjs";
import { MergeError, mergeIntoApple, pickSubscription } from "../src/merge.mjs";
import { accountToken, creditableTransaction, verifyAppleJWS } from "../src/purchase.mjs";
import { PurchaseRecords, transactionFacts } from "../src/purchaseRecords.mjs";
import { SubscriptionStore, subscriptionTransaction } from "../src/subscription.mjs";
import { FakeDDB } from "./fakeddb.mjs";

const config = {
  accountsTable: "accounts", ledgerTable: "ledger", promoTable: "promo", dailyTable: "daily", purchasesTable: "purchases",
  monthlyGrant: 0, signupBonus: 300, billingTimeZone: "America/Vancouver", subscriberMonthlyGrant: 50, subscriberMonthlyFairUse: 600,
  anonPerIpHour: 3, anonPerIpDay: 5,
};
const now = new Date("2026-10-19T18:00:00Z");
const DAY = 86400000;
const APPLE = "apple:001234.abcd";

function setup(over = {}) {
  const ddb = new FakeDDB();
  const cfg = { ...config, ...over };
  const store = new CreditStore(ddb, cfg);
  const subs = new SubscriptionStore(ddb, cfg);
  const purchases = new PurchaseRecords(ddb, cfg.purchasesTable);
  return { ddb, store, subs, purchases, anon: new AnonymousAccounts(ddb, store, cfg), deps: { ddb, store, subs, purchases, config: cfg } };
}
const account = (ddb, userId) => ddb.get("accounts", { userId });
const ledger = (ddb, userId) => [...ddb.table("ledger").values()].filter((e) => e.userId === userId).sort((a, b) => (a.at < b.at ? -1 : 1));
const rows = (ddb, table, userId) => [...ddb.table(table).values()].filter((r) => r.userId === userId);
const credits = async (store, userId) => toCredits((await store.balance(userId)).total);

/** A device account that has spent a little, bought 500 credits and holds a subscription. */
async function busyDevice(s) {
  const d = await s.anon.open({}, { ip: "1.1.1.1", now });
  const id = d.userId;
  // Spent 13 credits.
  const split = await s.store.reserve(id, 130, "r1");
  await s.store.settle(id, split, 130, "r1");
  // Bought a 500 pack: credited, with its marker and its purchases-table row.
  await s.store.creditPurchase(id, { transactionId: "t-500", productId: "ai.xiangyang.MenuLens.credits.500", credits: 500, environment: "Production" }, now);
  await s.purchases.record(id, { transactionId: "t-500", productId: "ai.xiangyang.MenuLens.credits.500", credits: 500, status: "credited" }, now);
  // An active monthly subscription, linked to it.
  const sub = { productId: "ai.xiangyang.MenuLens.sub.monthly", originalTransactionId: "o-1", transactionId: "o-1",
    expiresAt: new Date(now.getTime() + 20 * DAY).toISOString(), environment: "Production" };
  await s.subs.link(id, "o-1", now);
  await s.subs.apply(id, sub, now);
  await s.purchases.record(id, { type: "subscription", transactionId: "o-1", originalTransactionId: "o-1", status: "active" }, now);
  return d;
}

test("a device account opens with the 300 signup credits and a secret only the device knows", async () => {
  const s = setup();
  const d = await s.anon.open({}, { ip: "1.1.1.1", now });
  assert.ok(isAnonymous(d.userId));
  assert.equal(d.created, true);
  assert.equal(d.signupCredits, 300);
  assert.ok(d.deviceSecret.length >= 40);
  const a = account(s.ddb, d.userId);
  assert.equal(a.giftTenths, 3000);
  assert.equal(a.kind, "anonymous");
  assert.equal(a.deviceSecretHash, secretHash(d.deviceSecret));
  assert.ok(!JSON.stringify(a).includes(d.deviceSecret)); // the secret itself is never stored
  assert.deepEqual(ledger(s.ddb, d.userId).map((e) => [e.type, e.giftTenths]), [["signup", 3000]]);
  // Later launches (or a reinstall, the Keychain survives it) renew the same account, no new credits.
  const again = await s.anon.open({ deviceId: d.userId, deviceSecret: d.deviceSecret }, { ip: "1.1.1.1", now });
  assert.deepEqual(again, { userId: d.userId, created: false, signupCredits: 0 });
  assert.equal(account(s.ddb, d.userId).giftTenths, 3000);
  // A wrong secret is refused, as is something that isn't a device account.
  await assert.rejects(s.anon.open({ deviceId: d.userId, deviceSecret: "guess" }, { ip: "1.1.1.1", now }), DeviceAuthError);
  await assert.rejects(s.anon.open({ deviceId: APPLE, deviceSecret: "x" }, { ip: "1.1.1.1", now }), DeviceAuthError);
});

test("new device accounts are rate-limited per IP (hour and day); renewing one is not", async () => {
  const s = setup();
  const first = await s.anon.open({}, { ip: "2.2.2.2", now });
  await s.anon.open({}, { ip: "2.2.2.2", now });
  await s.anon.open({}, { ip: "2.2.2.2", now });
  await assert.rejects(s.anon.open({}, { ip: "2.2.2.2", now }), RateLimited);
  await s.anon.open({}, { ip: "3.3.3.3", now }); // another network
  const renewed = await s.anon.open({ deviceId: first.userId, deviceSecret: first.deviceSecret }, { ip: "2.2.2.2", now });
  assert.equal(renewed.created, false);
  // Next hour: the hourly window is free again, the daily one (5) still counts.
  const later = new Date(now.getTime() + 3600_000);
  await s.anon.open({}, { ip: "2.2.2.2", now: later });
  await s.anon.open({}, { ip: "2.2.2.2", now: later });
  await assert.rejects(s.anon.open({}, { ip: "2.2.2.2", now: later }), RateLimited);
  // The counters carry a TTL and no raw IP.
  const counters = [...s.ddb.table("promo").values()].filter((x) => x.code.startsWith("rate#anon#"));
  assert.ok(counters.length > 0 && counters.every((c) => c.expiresEpoch > now.getTime() / 1000 && !c.code.includes("2.2.2.2")));
});

test("clientIp: CloudFront's viewer address, else the last X-Forwarded-For entry, else the source", () => {
  assert.equal(clientIp({ headers: { "cloudfront-viewer-address": "203.0.113.9:51234" } }), "203.0.113.9");
  assert.equal(clientIp({ headers: { "x-forwarded-for": "6.6.6.6, 203.0.113.9" } }), "203.0.113.9");
  assert.equal(clientIp({ headers: {}, requestContext: { http: { sourceIp: "198.51.100.1" } } }), "198.51.100.1");
});

test("attach: a new Apple ID takes over the device account's balance, purchases and subscription, without a new 300", async () => {
  const s = setup();
  const d = await busyDevice(s);
  assert.equal(await credits(s.store, d.userId), 787);
  const r = await mergeIntoApple(d.userId, APPLE, s.deps, now);
  assert.equal(r.kind, "attach");
  assert.equal(toCredits(r.movedTenths), 787);
  const a = account(s.ddb, APPLE);
  assert.equal(await credits(s.store, APPLE), 787);
  assert.equal(a.paidTenths, 5000);
  assert.deepEqual(a.mergedFrom, [d.userId]);
  assert.equal(a.subscription.originalTransactionId, "o-1");
  assert.ok(!ledger(s.ddb, APPLE).some((e) => e.type === "signup"));
  assert.deepEqual(ledger(s.ddb, APPLE).map((e) => [e.type, e.giftTenths, e.paidTenths]), [["merge_in", 2870, 5000]]);
  // The device account is closed: empty, pointing at the Apple account, its history recorded.
  const closed = account(s.ddb, d.userId);
  assert.deepEqual([closed.giftTenths, closed.paidTenths, closed.mergedInto], [0, 0, APPLE]);
  const out = ledger(s.ddb, d.userId).find((e) => e.type === "merge_out");
  assert.deepEqual([out.giftTenths, out.paidTenths, out.ref], [-2870, -5000, APPLE]);
  assert.equal(rows(s.ddb, "daily", d.userId).length, 0);
  // What it owned now belongs to the Apple account.
  assert.equal(await s.subs.ownerOf("o-1"), APPLE);
  assert.equal(s.ddb.get("promo", { code: "iap#t-500", sk: "#purchase" }).userId, APPLE);
  assert.equal(rows(s.ddb, "purchases", d.userId).length, 0);
  assert.deepEqual(rows(s.ddb, "purchases", APPLE).map((x) => [x.transactionId, x.movedFrom]).sort(), [["o-1", d.userId], ["t-500", d.userId]]);
  // Signing in with Apple afterwards opens nothing new (no signup bonus on top).
  const { kind } = await s.store.grantIfDue(APPLE, now);
  assert.notEqual(kind, "signup");
  assert.equal(await credits(s.store, APPLE) >= 787, true);
});

test("merge: an Apple ID with an account gets the device balance added; ledgers on both sides", async () => {
  const s = setup();
  await s.store.grantIfDue(APPLE, now); // 300 at its own signup
  const split = await s.store.reserve(APPLE, 2000, "a1");
  await s.store.settle(APPLE, split, 2000, "a1"); // 100 left
  const d = await s.anon.open({}, { ip: "1.1.1.1", now });
  const r = await mergeIntoApple(d.userId, APPLE, s.deps, now);
  assert.equal(r.kind, "merge");
  assert.equal(await credits(s.store, APPLE), 400);
  assert.equal(await credits(s.store, d.userId), 0);
  // (the ledger's own entries carry the real clock, the move the test's `now`: find, don't sort)
  const into = ledger(s.ddb, APPLE).find((e) => e.type === "merge_in");
  const out = ledger(s.ddb, d.userId).find((e) => e.type === "merge_out");
  assert.deepEqual([into.giftTenths, into.ref], [3000, d.userId]);
  assert.deepEqual([out.giftTenths, out.ref], [-3000, APPLE]);
  // The rollup of the move's day shows the 300 coming in.
  const day = s.ddb.get("daily", { userId: APPLE, day: "2026-10-19" });
  assert.ok(day.addedTenths >= 3000);
});

test("merge keeps the Apple account's own subscription unless the device's runs longer", () => {
  const at = (days) => new Date(now.getTime() + days * DAY).toISOString();
  const mine = { originalTransactionId: "a", expiresAt: at(30) };
  assert.equal(pickSubscription(mine, { originalTransactionId: "b", expiresAt: at(10) }, now), null);
  assert.equal(pickSubscription(mine, { originalTransactionId: "b", expiresAt: at(90) }, now).originalTransactionId, "b");
  assert.equal(pickSubscription(mine, { originalTransactionId: "b", expiresAt: at(-1) }, now), null); // lapsed
  assert.equal(pickSubscription(undefined, { originalTransactionId: "b", expiresAt: at(-1) }, now).originalTransactionId, "b");
  assert.equal(pickSubscription(mine, undefined, now), null);
});

test("a retried link moves nothing twice", async () => {
  const s = setup();
  const d = await busyDevice(s);
  await mergeIntoApple(d.userId, APPLE, s.deps, now);
  const again = await mergeIntoApple(d.userId, APPLE, s.deps, now);
  assert.equal(again.kind, "already");
  assert.equal(again.movedTenths, 0);
  assert.equal(await credits(s.store, APPLE), 787);
  assert.equal(ledger(s.ddb, APPLE).filter((e) => e.type === "merge_in").length, 1);
  assert.equal(rows(s.ddb, "purchases", APPLE).length, 2);
  // Into a different Apple account: refused.
  await assert.rejects(mergeIntoApple(d.userId, "apple:someone-else", s.deps, now), (e) => e instanceof MergeError && e.reason === "conflict");
  // A deleted device account can't be linked.
  await assert.rejects(mergeIntoApple("anon:gone", APPLE, s.deps, now), (e) => e.reason === "no_account");
});

test("a link cut off after the money moved finishes on the retry", async () => {
  const s = setup();
  const d = await busyDevice(s);
  // The Lambda dies on its first write to the purchases table (step 2).
  let dead = true;
  s.ddb.before = async (kind, input) => {
    if (dead && kind === "Put" && input.TableName === "purchases") { dead = false; throw new Error("Lambda timed out"); }
  };
  await assert.rejects(mergeIntoApple(d.userId, APPLE, s.deps, now), /timed out/);
  assert.equal(await credits(s.store, APPLE), 787); // step 1 is all or nothing: already done
  assert.equal(rows(s.ddb, "purchases", d.userId).length, 2); // step 2 not yet
  // Meanwhile the app (already on the Apple session) sends its subscription: the link held by the
  // closed device account is taken over rather than refused.
  await s.subs.link(APPLE, "o-1", now);
  assert.equal(await s.subs.ownerOf("o-1"), APPLE);
  const r = await mergeIntoApple(d.userId, APPLE, s.deps, now);
  assert.equal(r.kind, "already");
  assert.equal(await credits(s.store, APPLE), 787);
  assert.equal(rows(s.ddb, "purchases", d.userId).length, 0);
  assert.equal(rows(s.ddb, "purchases", APPLE).length, 2);
  assert.equal(s.ddb.get("promo", { code: "iap#t-500", sk: "#purchase" }).userId, APPLE);
});

test("a charge racing the link is moved correctly, and a late refund into the closed account is swept", async () => {
  const s = setup();
  const d = await s.anon.open({}, { ip: "1.1.1.1", now });
  // A scan reserves 8 credits between the link's read and its transaction.
  let raced = false;
  s.ddb.before = async (kind) => {
    if (kind === "TransactWrite" && !raced) { raced = true; s.ddb.before = null; held = await s.store.reserve(d.userId, 80, "scan"); }
  };
  let held;
  await mergeIntoApple(d.userId, APPLE, s.deps, now);
  assert.equal(await credits(s.store, APPLE), 292); // the stale 300 was not moved: re-read, then 292
  // The scan finishes after the move: 5 of the 8 come back to the closed account…
  await s.store.settle(d.userId, held, 30, "scan");
  assert.equal(await credits(s.store, d.userId), 5);
  // …and the next link call (the app retries until it has the session) sweeps them over.
  await mergeIntoApple(d.userId, APPLE, s.deps, now);
  assert.equal(await credits(s.store, APPLE), 297);
  assert.equal(await credits(s.store, d.userId), 0);
});

test("after the move, the device's secret gives a new EMPTY device account; so does a deleted one", async () => {
  const s = setup();
  const d = await s.anon.open({}, { ip: "1.1.1.1", now });
  await mergeIntoApple(d.userId, APPLE, s.deps, now);
  const next = await s.anon.open({ deviceId: d.userId, deviceSecret: d.deviceSecret }, { ip: "1.1.1.1", now });
  assert.equal(next.created, true);
  assert.notEqual(next.userId, d.userId);
  assert.equal(next.signupCredits, 0);
  assert.equal(account(s.ddb, next.userId).predecessor, d.userId);
  assert.equal(await credits(s.store, next.userId), 0);

  // Deleting a device account works like any account (no Apple token to revoke) and leaves a
  // tombstone: the device then starts again without the 300.
  await s.store.deleteAccount(next.userId, now);
  assert.equal(account(s.ddb, next.userId), undefined);
  const after = await s.anon.open({ deviceId: next.userId, deviceSecret: next.deviceSecret }, { ip: "1.1.1.1", now });
  assert.equal(after.signupCredits, 0);
});

// --- App Store Offer Codes and purchase tokens after a move ---------------------------------

const dir = new URL("./fixtures/iap/", import.meta.url);
const pem = (f) => readFileSync(new URL(f, dir), "utf8");
const x5c = ["leaf.pem", "int.pem", "root.pem"].map((f) => new X509Certificate(pem(f)).raw.toString("base64"));
const leafKey = createPrivateKey(pem("leaf.pk8"));
const verify = (j) => verifyAppleJWS(j, { rootFingerprint: new X509Certificate(pem("root.pem")).fingerprint256 });
function jws(payload) {
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = `${enc({ alg: "ES256", x5c })}.${enc(payload)}`;
  return `${head}.${sign("sha256", Buffer.from(head), { key: leafKey, dsaEncoding: "ieee-p1363" }).toString("base64url")}`;
}
const BUNDLE = "ai.xiangyang.MenuLens";

test("an Offer Code redemption of a credit pack (no account token, price 0) is credited once", async () => {
  const s = setup();
  const d = await s.anon.open({}, { ip: "1.1.1.1", now });
  // Redeemed in the App Store app: StoreKit hands it to the app via Transaction.updates, without
  // the appAccountToken our own purchases carry.
  const payload = verify(jws({
    transactionId: "t-offer", originalTransactionId: "t-offer", productId: "ai.xiangyang.MenuLens.credits.100", type: "Consumable",
    bundleId: BUNDLE, environment: "Production", quantity: 1, price: 0, currency: "USD", storefront: "USA",
    offerType: 3, offerIdentifier: "LAUNCH-100",
  }));
  const tx = creditableTransaction(payload, { userId: d.userId, bundleId: BUNDLE, allowSandbox: false });
  assert.equal(tx.credits, 100);
  assert.deepEqual(await s.store.creditPurchase(d.userId, tx, now), { credited: true, credits: 100 });
  assert.deepEqual(await s.store.creditPurchase(d.userId, tx, now), { credited: false, credits: 100 }); // the app retries
  assert.equal(await credits(s.store, d.userId), 400);
  const facts = transactionFacts(payload);
  assert.deepEqual([facts.price, facts.offerType, facts.offerIdentifier], [0, 3, "LAUNCH-100"]);
  // Redeemed in the app's own sheet it may carry the token: still fine. Someone else's: refused.
  assert.ok(creditableTransaction({ ...payload, appAccountToken: accountToken(d.userId) }, { userId: d.userId, bundleId: BUNDLE, allowSandbox: false }));
  assert.throws(() => creditableTransaction({ ...payload, appAccountToken: accountToken("apple:x") }, { userId: d.userId, bundleId: BUNDLE, allowSandbox: false }),
    (e) => e.reason === "wrong_account");
});

test("after a move, transactions carrying the device account's token count as the Apple account's", async () => {
  const s = setup();
  const d = await busyDevice(s);
  await mergeIntoApple(d.userId, APPLE, s.deps, now);
  const aliases = account(s.ddb, APPLE).mergedFrom;
  const pack = { transactionId: "t-late", productId: "ai.xiangyang.MenuLens.credits.100", type: "Consumable", bundleId: BUNDLE,
    environment: "Production", appAccountToken: accountToken(d.userId) };
  assert.throws(() => creditableTransaction(pack, { userId: APPLE, bundleId: BUNDLE, allowSandbox: false }), (e) => e.reason === "wrong_account");
  assert.equal(creditableTransaction(pack, { userId: APPLE, aliases, bundleId: BUNDLE, allowSandbox: false }).credits, 100);
  const renewal = { transactionId: "o-2", originalTransactionId: "o-1", productId: "ai.xiangyang.MenuLens.sub.monthly",
    type: "Auto-Renewable Subscription", bundleId: BUNDLE, environment: "Production", appAccountToken: accountToken(d.userId),
    expiresDate: now.getTime() + 50 * DAY };
  assert.equal(subscriptionTransaction(renewal, { userId: APPLE, aliases, bundleId: BUNDLE, allowSandbox: false }).transactionId, "o-2");
  assert.deepEqual(await s.subs.aliasesOf(APPLE), [d.userId]);
  // The pack the device account was credited for is a duplicate for the Apple account, not a conflict…
  const old = { transactionId: "t-500", productId: "ai.xiangyang.MenuLens.credits.500", credits: 500, environment: "Production" };
  assert.deepEqual(await s.store.creditPurchase(APPLE, old, now), { credited: false, credits: 500 });
  // …and still a conflict for anyone else.
  await s.store.grantIfDue("apple:other", now);
  await assert.rejects(s.store.creditPurchase("apple:other", old, now), PurchaseConflict);
});
