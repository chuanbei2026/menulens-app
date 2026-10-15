import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createPrivateKey, sign, X509Certificate } from "node:crypto";
import { test } from "node:test";
import { CreditStore, PurchaseConflict } from "../src/credits.mjs";
import { accountToken, creditableTransaction, oidBytes, PRODUCTS, PurchaseError, verifyAppleJWS } from "../src/purchase.mjs";

// A throwaway chain shaped like Apple's (see fixtures/iap/make-chain.sh).
const dir = new URL("./fixtures/iap/", import.meta.url);
const pem = (f) => readFileSync(new URL(f, dir), "utf8");
const der = (p) => new X509Certificate(p).raw.toString("base64");
const root = new X509Certificate(pem("root.pem"));
const x5c = [der(pem("leaf.pem")), der(pem("int.pem")), der(pem("root.pem"))];
const leafKey = createPrivateKey(pem("leaf.pk8"));
const opts = { rootFingerprint: root.fingerprint256 };

function jws(payload, { chain = x5c, key = leafKey } = {}) {
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = `${enc({ alg: "ES256", x5c: chain })}.${enc(payload)}`;
  const sig = sign("sha256", Buffer.from(head), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${head}.${sig}`;
}

const userId = "apple:000123.abc";
const payload = {
  transactionId: "2000000123456789", productId: "ai.xiangyang.MenuLens.credits.500", type: "Consumable",
  bundleId: "ai.xiangyang.MenuLens", environment: "Production", quantity: 1, appAccountToken: accountToken(userId),
};
const ctx = { userId, bundleId: "ai.xiangyang.MenuLens", allowSandbox: false };

test("a correctly signed transaction verifies and credits base + 10%", () => {
  const p = verifyAppleJWS(jws(payload), opts);
  assert.deepEqual(creditableTransaction(p, ctx),
    { transactionId: payload.transactionId, productId: payload.productId, environment: "Production", credits: 550 });
});

test("every product carries a 10% bonus", () => {
  for (const { credits, bonus } of Object.values(PRODUCTS)) assert.equal(bonus, credits / 10);
});

test("Apple's root is pinned: a chain to any other root is rejected", () => {
  assert.throws(() => verifyAppleJWS(jws(payload)), (e) => e instanceof PurchaseError && e.reason === "untrusted_root");
});

test("tampered payloads and foreign signatures fail", () => {
  const [h, , s] = jws(payload).split(".");
  const forged = Buffer.from(JSON.stringify({ ...payload, productId: "ai.xiangyang.MenuLens.credits.2000" })).toString("base64url");
  assert.throws(() => verifyAppleJWS(`${h}.${forged}.${s}`, opts), (e) => e.reason === "bad_signature");
  assert.throws(() => verifyAppleJWS("a.b", opts), (e) => e.reason === "bad_jws");
  // A chain without the intermediate does not link the leaf to the root.
  assert.throws(() => verifyAppleJWS(jws(payload, { chain: [x5c[0], x5c[2]] }), opts), (e) => e.reason === "bad_certificate");
});

test("the leaf must carry Apple's receipt-signing extension", () => {
  assert.ok(new X509Certificate(pem("leaf.pem")).raw.includes(oidBytes("1.2.840.113635.100.6.11.1")));
  // The intermediate is a valid CA cert but not a signing leaf.
  assert.throws(() => verifyAppleJWS(jws(payload, { chain: [x5c[1], x5c[2]] }), opts), (e) => e.reason === "bad_certificate");
});

test("payload checks: app, product, environment, account, revocation", () => {
  const check = (p, c = ctx) => () => creditableTransaction({ ...payload, ...p }, c);
  assert.throws(check({ bundleId: "com.other.app" }), (e) => e.reason === "wrong_app");
  assert.throws(check({ productId: "ai.xiangyang.MenuLens.credits.999" }), (e) => e.reason === "unknown_product");
  assert.throws(check({ environment: "Sandbox" }), (e) => e.reason === "wrong_environment");
  assert.equal(check({ environment: "Sandbox" }, { ...ctx, allowSandbox: true })().credits, 550);
  assert.throws(check({ environment: "Xcode" }, { ...ctx, allowSandbox: true }), (e) => e.reason === "wrong_environment");
  assert.throws(check({ appAccountToken: accountToken("apple:someone-else") }), (e) => e.reason === "wrong_account");
  assert.throws(check({ revocationDate: 1760000000000 }), (e) => e.reason === "revoked");
});

test("account tokens are stable UUIDs per user", () => {
  assert.match(accountToken(userId), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-a[0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(accountToken(userId), accountToken(userId));
  assert.notEqual(accountToken(userId), accountToken("apple:other"));
});

test("a transaction is credited once, and never to a second account", async () => {
  const markers = new Map();
  let paid = 0;
  const ddb = { async send(cmd) {
    const name = cmd.constructor.name;
    if (name === "TransactWriteCommand") {
      const put = cmd.input.TransactItems[0].Put.Item;
      if (markers.has(put.code)) {
        throw Object.assign(new Error("cancelled"), { name: "TransactionCanceledException", CancellationReasons: [{ Code: "ConditionalCheckFailed" }, { Code: "None" }] });
      }
      markers.set(put.code, put);
      paid += cmd.input.TransactItems[1].Update.ExpressionAttributeValues[":c"];
      return {};
    }
    if (name === "GetCommand") return { Item: markers.get(cmd.input.Key.code) };
    return {}; // ledger writes
  } };
  const store = new CreditStore(ddb, { promoTable: "p", accountsTable: "a", ledgerTable: "l", dailyTable: "d", billingTimeZone: "UTC" });
  const tx = { transactionId: "t1", productId: "ai.xiangyang.MenuLens.credits.100", credits: 110, environment: "Production" };
  assert.deepEqual(await store.creditPurchase(userId, tx), { credited: true, credits: 110 });
  assert.deepEqual(await store.creditPurchase(userId, tx), { credited: false, credits: 110 });
  await assert.rejects(store.creditPurchase("apple:other", tx), PurchaseConflict);
  assert.equal(paid, 1100); // stored in tenths of a credit: 110 credits
});
