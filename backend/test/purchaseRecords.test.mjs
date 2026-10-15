import assert from "node:assert/strict";
import { test } from "node:test";
import { PurchaseRecords, transactionFacts } from "../src/purchaseRecords.mjs";
import { FakeDDB } from "./fakeddb.mjs";

test("the facts of a StoreKit 2 transaction: price from milli-units, dates as ISO, empty fields dropped", () => {
  const f = transactionFacts({ transactionId: "2000001", originalTransactionId: "2000001", productId: "ai.xiangyang.MenuLens.credits.100",
    quantity: 1, price: 990, currency: "USD", storefront: "USA", environment: "Sandbox", purchaseDate: 1_800_000_000_000, appAccountToken: "x" });
  assert.deepEqual(f, { transactionId: "2000001", originalTransactionId: "2000001", productId: "ai.xiangyang.MenuLens.credits.100",
    quantity: 1, price: 0.99, currency: "USD", storefront: "USA", environment: "Sandbox", purchaseDate: "2027-01-15T08:00:00.000Z" });
  assert.deepEqual(transactionFacts(null), {});
});

test("records are kept per user, newest first, rejected ones included", async () => {
  const ddb = new FakeDDB();
  const r = new PurchaseRecords(ddb, "purchases");
  await r.record("u", { transactionId: "t1", status: "credited", credits: 100, price: 0.99, currency: "USD" }, new Date("2026-10-15T10:00:00Z"));
  await r.record("u", { transactionId: "t2", status: "rejected", reason: "wrong_account" }, new Date("2026-10-15T11:00:00Z"));
  await r.record("other", { transactionId: "t3", status: "credited" }, new Date("2026-10-15T12:00:00Z"));
  const list = await r.list("u");
  assert.deepEqual(list.map((p) => [p.transactionId, p.status]), [["t2", "rejected"], ["t1", "credited"]]);
  assert.equal(list[1].sk, "2026-10-15T10:00:00.000Z#t1");
});

test("a failed write never throws (the purchase must still succeed)", async () => {
  const r = new PurchaseRecords({ send: async () => { throw new Error("throttled"); } }, "purchases");
  await r.record("u", { transactionId: "t1", status: "credited" });
});
