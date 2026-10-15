// CreditStore end to end on an in-memory DynamoDB (test/fakeddb.mjs): tenths of a credit, the
// lazy move of old whole-credit accounts, reservation / refund, and that nothing drifts.
import assert from "node:assert/strict";
import { test } from "node:test";
import { CreditStore, InsufficientCredits, balanceHistory, billingDay, publicBalance, toCredits } from "../src/credits.mjs";
import { FakeDDB } from "./fakeddb.mjs";

const config = {
  accountsTable: "accounts", ledgerTable: "ledger", promoTable: "promo", dailyTable: "daily",
  monthlyGrant: 100, signupBonus: 200, billingTimeZone: "America/Vancouver",
};
const now = new Date();
const thisMonth = billingDay(now, config.billingTimeZone).slice(0, 7);

function setup() {
  const ddb = new FakeDDB();
  return { ddb, store: new CreditStore(ddb, config) };
}

const account = (ddb, userId) => ddb.get("accounts", { userId });
const ledger = (ddb, userId) => [...ddb.table("ledger").values()].filter((e) => e.userId === userId).sort((a, b) => (a.at < b.at ? -1 : 1));

test("a new account starts with 300 credits, stored as tenths", async () => {
  const { ddb, store } = setup();
  const { kind } = await store.grantIfDue("u1", now);
  assert.equal(kind, "signup");
  assert.equal(account(ddb, "u1").giftTenths, 3000);
  assert.equal(account(ddb, "u1").paidTenths, 0);
  assert.deepEqual(ledger(ddb, "u1").map((e) => [e.type, e.giftTenths]), [["signup", 2000], ["monthly_grant", 1000]]);
  const [row] = await store.dailyRows("u1", 30);
  assert.equal(row.added, 3000);
  assert.equal(toCredits((await store.balance("u1")).total), 300);
});

test("an old whole-credit account reads correctly and moves to tenths on first use, keeping the old values", async () => {
  const { ddb, store } = setup();
  ddb.put("accounts", { userId: "old", giftCredits: 287, paidCredits: 110, grantPeriod: thisMonth, version: 12 }, ["userId"]);
  // Reading (GET /credits, /usage) doesn't write.
  const before = publicBalance(await store.balance("old"));
  assert.equal(before.totalCredits, 397);
  assert.equal(before.totalCredits, 397);
  assert.equal(ddb.calls.filter((c) => c.kind === "Update").length, 0);

  const { kind, item } = await store.grantIfDue("old", now);
  assert.equal(kind, null); // already granted this month
  const a = account(ddb, "old");
  assert.equal(a.giftTenths, 2870);
  assert.equal(a.paidTenths, 1100);
  assert.equal(a.giftCredits, undefined);
  assert.equal(a.paidCredits, undefined);
  assert.deepEqual({ ...a.legacyCredits, migratedAt: undefined }, { giftCredits: 287, paidCredits: 110, migratedAt: undefined });
  assert.equal(a.version, 13);
  assert.equal(item.giftTenths, 2870);
  assert.equal(toCredits((await store.balance("old")).total), 397);

  // Migrating twice is a no-op.
  await store.grantIfDue("old", now);
  assert.equal(account(ddb, "old").version, 13);
});

test("an old account from last month is moved and granted in one go; a per-user override is whole credits", async () => {
  const { ddb, store } = setup();
  ddb.put("accounts", { userId: "a", giftCredits: 5, paidCredits: 0, grantPeriod: "2020-01", version: 3 }, ["userId"]);
  ddb.put("accounts", { userId: "b", giftCredits: 0, paidCredits: 0, grantPeriod: "2020-01", version: 1, monthlyGrant: 2000 }, ["userId"]);
  assert.equal((await store.grantIfDue("a", now)).kind, "monthly");
  assert.equal((await store.grantIfDue("b", now)).kind, "monthly");
  assert.equal(account(ddb, "a").giftTenths, 50 + 1000);
  assert.equal(account(ddb, "b").giftTenths, 20000);
  assert.equal(ledger(ddb, "b").at(-1).giftTenths, 20000);
  // A second request the same month grants nothing.
  assert.equal((await store.grantIfDue("a", now)).kind, null);
  assert.equal(account(ddb, "a").giftTenths, 1050);
});

test("reserve the worst case, settle the actual 0.3: the balance is exactly 299.7", async () => {
  const { ddb, store } = setup();
  const { item } = await store.grantIfDue("u", now);
  const split = await store.reserve("u", 128, "r1", item);
  assert.deepEqual(split, { fromGift: 128, fromPaid: 0 });
  assert.equal(account(ddb, "u").giftTenths, 3000 - 128);
  await store.settle("u", split, 3, "r1");
  const b = await store.balance("u");
  assert.equal(toCredits(b.total), 299.7);
  assert.equal(publicBalance(b).totalCredits, 299);
  const settle = ledger(ddb, "u").at(-1);
  assert.deepEqual([settle.type, settle.giftTenths, settle.chargedTenths], ["settle", 125, 3]);
  const [row] = await store.dailyRows("u", 30);
  assert.deepEqual([row.spent, row.calls], [3, 1]);
});

test("refunds go back to paid credits first; a failed call refunds everything", async () => {
  const { ddb, store } = setup();
  ddb.put("accounts", { userId: "p", giftTenths: 5, paidTenths: 1000, grantPeriod: thisMonth, version: 1 }, ["userId"]);
  const split = await store.reserve("p", 50, "r");
  assert.deepEqual(split, { fromGift: 5, fromPaid: 45 });
  await store.settle("p", split, 3, "r"); // 0.3 used: 4.7 back, paid first
  assert.deepEqual([account(ddb, "p").giftTenths, account(ddb, "p").paidTenths], [2, 1000]);
  const again = await store.reserve("p", 50, "r2");
  await store.settle("p", again, 0, "r2");
  assert.deepEqual([account(ddb, "p").giftTenths, account(ddb, "p").paidTenths], [2, 1000]);
});

test("a short balance is refused, with the balance in tenths", async () => {
  const { ddb, store } = setup();
  ddb.put("accounts", { userId: "s", giftTenths: 5, paidTenths: 0, grantPeriod: thisMonth, version: 1 }, ["userId"]);
  await assert.rejects(store.reserve("s", 6, "r"), (e) => e instanceof InsufficientCredits && e.balance.total === 5);
  assert.equal(account(ddb, "s").giftTenths, 5);
  assert.deepEqual(await store.reserve("s", 5, "r"), { fromGift: 5, fromPaid: 0 });
});

test("concurrent reservations never spend the same tenths twice", async () => {
  const { ddb, store } = setup();
  ddb.put("accounts", { userId: "c", giftTenths: 10, paidTenths: 0, grantPeriod: thisMonth, version: 1 }, ["userId"]);
  const results = await Promise.allSettled([store.reserve("c", 6, "a"), store.reserve("c", 6, "b")]);
  assert.deepEqual(results.map((r) => r.status).sort(), ["fulfilled", "rejected"]);
  assert.ok(results.find((r) => r.status === "rejected").reason instanceof InsufficientCredits);
  assert.equal(account(ddb, "c").giftTenths, 4);
});

test("reserving on an account that was never moved moves it first (no stray whole-credit math)", async () => {
  const { ddb, store } = setup();
  const old = { userId: "o", giftCredits: 2, paidCredits: 0, grantPeriod: thisMonth, version: 7 };
  ddb.put("accounts", old, ["userId"]);
  assert.deepEqual(await store.reserve("o", 3, "r", old), { fromGift: 3, fromPaid: 0 });
  assert.equal(account(ddb, "o").giftTenths, 17);
});

test("a concurrent change during the move makes it re-read instead of overwriting", async () => {
  const { ddb, store } = setup();
  ddb.put("accounts", { userId: "m", giftCredits: 10, paidCredits: 0, grantPeriod: thisMonth, version: 4 }, ["userId"]);
  let raced = false;
  ddb.before = async (kind, input) => {
    if (!raced && kind === "Update" && input.UpdateExpression.includes("legacyCredits")) {
      raced = true; // an in-flight request on the old code spends 1 whole credit first
      const a = ddb.get("accounts", { userId: "m" });
      ddb.put("accounts", { ...a, giftCredits: 9, version: 5 }, ["userId"]);
    }
  };
  await store.grantIfDue("m", now);
  assert.equal(account(ddb, "m").giftTenths, 90);
  assert.equal(account(ddb, "m").legacyCredits.giftCredits, 9);
});

test("promotions and purchases add whole credits as tenths", async () => {
  const { ddb, store } = setup();
  ddb.put("accounts", { userId: "x", giftCredits: 1, paidCredits: 0, grantPeriod: thisMonth, version: 1 }, ["userId"]);
  ddb.put("promo", { code: "LOVEGULU", sk: "#meta", credits: 2000, active: true, redemptions: 0, displayName: "LoveGulu" }, ["code", "sk"]);
  // Unmoved accounts are refused rather than mixing units (every route calls grantIfDue first).
  await assert.rejects(store.redeemPromo("x", "love gulu", now), (e) => e.name === "TransactionCanceledException");
  await store.grantIfDue("x", now);
  assert.deepEqual(await store.redeemPromo("x", "love gulu", now), { code: "LoveGulu", credits: 2000 });
  assert.equal(account(ddb, "x").giftTenths, 20010);
  const tx = { transactionId: "t9", productId: "ai.xiangyang.MenuLens.credits.500", credits: 550, environment: "Sandbox" };
  assert.deepEqual(await store.creditPurchase("x", tx, now), { credited: true, credits: 550 });
  assert.equal(account(ddb, "x").paidTenths, 5500);
  assert.equal(toCredits((await store.balance("x")).total), 2551);
  assert.deepEqual(ledger(ddb, "x").slice(-2).map((e) => [e.type, e.giftTenths, e.paidTenths]), [["promo", 20000, 0], ["purchase", 0, 5500]]);
});

test("hundreds of tool-round charges: balance, ledger and daily rollup agree to the tenth", async () => {
  const { ddb, store } = setup();
  await store.grantIfDue("d", now);
  let charged = 0;
  for (let i = 0; i < 500; i++) {
    const actual = 1 + (i * 7) % 9; // 0.1 … 0.9
    const split = await store.reserve("d", 40, `r${i}`);
    await store.settle("d", split, actual, `r${i}`);
    charged += actual;
  }
  const b = await store.balance("d");
  assert.equal(b.total, 3000 - charged);
  const ledgerSum = ledger(ddb, "d").reduce((s, e) => s + e.giftTenths + e.paidTenths, 0);
  assert.equal(ledgerSum, b.total);
  const rows = await store.dailyRows("d", 30);
  assert.equal(rows.reduce((s, r) => s + r.spent, 0), charged);
  assert.equal(rows.reduce((s, r) => s + r.calls, 0), 500);
  const days = balanceHistory(rows, { balance: b.total, days: 30, timeZone: config.billingTimeZone, now });
  assert.equal(days[0].balance, 0); // before the account existed
  assert.equal(toCredits(days.at(-1).balance), (3000 - charged) / 10);
  assert.ok(Number.isInteger(publicBalance(b).totalCredits));
});

test("deleting an account removes the balance and daily rows", async () => {
  const { ddb, store } = setup();
  await store.grantIfDue("del", now);
  await store.deleteAccount("del", now);
  assert.equal(account(ddb, "del"), undefined);
  assert.equal((await store.dailyRows("del", 30)).length, 0);
  // Coming back: no second signup bonus.
  assert.equal((await store.grantIfDue("del", now)).kind, "reopen");
  assert.equal(account(ddb, "del").giftTenths, 0);
});

test("ForeignMenu: 300 at signup and no monthly grant — no zero entries, no writes in later months", async () => {
  const ddb = new FakeDDB();
  const store = new CreditStore(ddb, { ...config, monthlyGrant: 0, signupBonus: 300 });
  const { kind } = await store.grantIfDue("f", now);
  assert.equal(kind, "signup");
  assert.equal(account(ddb, "f").giftTenths, 3000);
  assert.deepEqual(ledger(ddb, "f").map((e) => e.type), ["signup"]);
  // Next month: nothing is granted and nothing is written.
  const next = new Date(now.getTime() + 40 * 86400 * 1000);
  const writes = ddb.calls.length;
  assert.equal((await store.grantIfDue("f", next)).kind, null);
  assert.equal(ddb.calls.filter((c, i) => i >= writes && c.kind !== "Get").length, 0);
  assert.equal(account(ddb, "f").giftTenths, 3000);
});
