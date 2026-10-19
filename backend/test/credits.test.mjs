import assert from "node:assert/strict";
import { test } from "node:test";
import {
  accountTenths, balanceHistory, billingPeriod, entryTenths, estimateInputTokens, nextPeriod, publicBalance,
  publicDay, rollupDelta, rowTenths, settlementDeltas, splitCharge, tenthsFor, toCredits, toTenths,
} from "../src/credits.mjs";

test("billing month follows the billing time zone, not UTC", () => {
  // 2026-11-01 06:30 UTC is still Oct 31 in Vancouver (UTC-7).
  assert.equal(billingPeriod(new Date("2026-11-01T06:30:00Z"), "America/Vancouver"), "2026-10");
  assert.equal(billingPeriod(new Date("2026-11-01T08:30:00Z"), "America/Vancouver"), "2026-11");
});

test("next period rolls over the year", () => {
  assert.equal(nextPeriod("2026-10"), "2026-11");
  assert.equal(nextPeriod("2026-12"), "2027-01");
});

test("charges weigh output tokens, round up to 0.1 credit and never below 0.1", () => {
  // Amounts are tenths of a credit: 6 = 0.6 credit.
  assert.equal(tenthsFor(698, 672, 4), 6);    // the diary extraction measured earlier: 3386 / 6000 = 0.56 → 0.6
  assert.equal(tenthsFor(3083, 502, 4), 9);   // an agent step reading one screenshot: 0.85 → 0.9
  assert.equal(tenthsFor(10, 2, 4), 1);       // tiny → 0.1, never 0
  assert.equal(tenthsFor(0, 0, 4), 1);
  assert.equal(tenthsFor(1380, 0, 4), 3);     // 0.23 → 0.3
  assert.equal(tenthsFor(1200, 0, 4), 2);     // exactly 0.2 stays 0.2
  assert.equal(tenthsFor(1201, 0, 4), 3);     // a token over → 0.3
  assert.equal(tenthsFor(6000, 0, 4), 10);    // exactly 1 credit
  assert.equal(tenthsFor(6001, 0, 4), 11);
  // Output at the model's 6× price ratio: a maximal agent answer (4000 out) on a big transcript.
  assert.equal(tenthsFor(52260, 4000, 6), 128); // 12.71 → 12.8 (was 13 when rounding to whole credits)
  assert.equal(tenthsFor(4001, 0, 4, 4000), 11); // an earlier rate
});

test("tenths convert to credits with at most one decimal, exactly", () => {
  assert.equal(toTenths(100), 1000);
  assert.equal(toTenths(2000), 20000);
  assert.equal(toTenths(undefined), 0);
  assert.equal(toCredits(2874), 287.4);
  assert.equal(JSON.stringify({ c: toCredits(2874), d: toCredits(3), e: toCredits(3000), f: toCredits(-3) }), '{"c":287.4,"d":0.3,"e":300,"f":-0.3}');
  for (let t = -50; t <= 50000; t += 7) assert.ok(/^-?\d+(\.\d)?$/.test(String(toCredits(t))), String(toCredits(t)));
});

test("many small charges add up exactly (no floating-point drift)", () => {
  // 10 000 charges of 0.1 and 0.3 against 3000 credits, the way DynamoDB adds them (integers).
  let balance = toTenths(3000);
  let spent = 0;
  for (let i = 0; i < 10000; i++) {
    const charge = i % 2 ? 1 : 3;
    const split = splitCharge({ gift: balance, paid: 0 }, charge);
    balance -= split.fromGift;
    spent += charge;
  }
  assert.equal(spent, 20000);
  assert.equal(balance, 10000);
  assert.equal(toCredits(balance), 1000);
  // The same in floating-point credits drifts — the reason amounts are integers.
  let float = 3000;
  for (let i = 0; i < 10000; i++) float -= i % 2 ? 0.1 : 0.3;
  assert.notEqual(float, 1000);
});

test("input estimate is an upper bound for English and Chinese", () => {
  assert.ok(estimateInputTokens("hello world, this is english text") >= 8);
  assert.ok(estimateInputTokens("今天在温哥华见了朋友") >= 10);
});

test("charges take gift credits first, then paid", () => {
  assert.deepEqual(splitCharge({ gift: 300, paid: 50 }, 4), { fromGift: 4, fromPaid: 0 });
  assert.deepEqual(splitCharge({ gift: 2, paid: 50 }, 5), { fromGift: 2, fromPaid: 3 });
  assert.deepEqual(splitCharge({ gift: 0, paid: 5 }, 5), { fromGift: 0, fromPaid: 5 });
  assert.equal(splitCharge({ gift: 2, paid: 2 }, 5), null);
  assert.deepEqual(splitCharge({ gift: -1, paid: 3 }, 3), { fromGift: 0, fromPaid: 3 }); // after an overrun
});

test("settlement refunds paid first, overruns hit gift", () => {
  assert.deepEqual(settlementDeltas({ fromGift: 2, fromPaid: 7 }, 4), { gift: 0, paid: 5 });
  assert.deepEqual(settlementDeltas({ fromGift: 3, fromPaid: 2 }, 1), { gift: 2, paid: 2 });
  assert.deepEqual(settlementDeltas({ fromGift: 9, fromPaid: 0 }, 9), { gift: 0, paid: 0 });
  assert.deepEqual(settlementDeltas({ fromGift: 5, fromPaid: 0 }, 7), { gift: -2, paid: 0 });
  assert.deepEqual(settlementDeltas({ fromGift: 3, fromPaid: 2 }, 0), { gift: 3, paid: 2 }); // full refund
});

test("rollup: holds and settlements are spending, grants and promotions are additions (tenths)", () => {
  assert.deepEqual(rollupDelta({ type: "hold", giftTenths: -40, paidTenths: -2 }), { spent: 42, added: 0, calls: 1, covered: 0 });
  assert.deepEqual(rollupDelta({ type: "settle", giftTenths: 37, paidTenths: 0 }), { spent: -37, added: 0, calls: 0, covered: 0 });
  assert.deepEqual(rollupDelta({ type: "promo", giftTenths: 20000, paidTenths: 0 }), { spent: 0, added: 20000, calls: 0, covered: 0 });
  // A call a subscription covered: nothing spent, what it would have cost counted as covered.
  assert.deepEqual(rollupDelta({ type: "hold", giftTenths: 0, paidTenths: 0, coveredHoldTenths: 128 }), { spent: 0, added: 0, calls: 1, covered: 0 });
  assert.deepEqual(rollupDelta({ type: "settle", giftTenths: 0, paidTenths: 0, chargedTenths: 0, coveredTenths: 53 }), { spent: 0, added: 0, calls: 0, covered: 53 });
});

test("old whole-credit records read as tenths", () => {
  // Ledger entries before the switch: gift / paid in whole credits.
  assert.deepEqual(entryTenths({ type: "hold", gift: -4, paid: -1 }), { gift: -40, paid: -10 });
  assert.deepEqual(rollupDelta({ type: "promo", gift: 2000, paid: 0 }), { spent: 0, added: 20000, calls: 0, covered: 0 });
  assert.deepEqual(rollupDelta({ type: "settle", gift: 3, paid: 0, charged: 1 }), { spent: -30, added: 0, calls: 0, covered: 0 });
  // Accounts not yet migrated; migrated ones win even when both are present.
  assert.deepEqual(accountTenths({ giftCredits: 287, paidCredits: 110 }), { gift: 2870, paid: 1100 });
  assert.deepEqual(accountTenths({ giftCredits: -2 }), { gift: -20, paid: 0 });
  assert.deepEqual(accountTenths({ giftTenths: 2874, paidTenths: 0, giftCredits: 999 }), { gift: 2874, paid: 0 });
  // The day of the switch holds whole credits (before) and tenths (after) side by side.
  assert.deepEqual(rowTenths({ day: "2026-10-14", spent: 5, added: 100, spentTenths: 7, calls: 6 }),
    { day: "2026-10-14", spent: 57, added: 1000, calls: 6, covered: 0 });
  assert.deepEqual(rowTenths({ day: "2026-10-15", spentTenths: 3, addedTenths: 0, calls: 1 }), { day: "2026-10-15", spent: 3, added: 0, calls: 1, covered: 0 });
});

test("API amounts are whole credits only", () => {
  assert.deepEqual(publicBalance({ total: 2874, gift: 1774, paid: 1100, monthlyGrant: 100, lastGrantPeriod: "2026-10" }), {
    totalCredits: 287, giftCredits: 177, paidCredits: 110,
    monthlyGrant: 100, lastGrantPeriod: "2026-10",
  });
  // After an overrun gift can be slightly negative; the integer never claims more than there is.
  const b = publicBalance({ total: 50, gift: -3, paid: 50, monthlyGrant: 100 });
  assert.equal(b.giftCredits, -1);
  assert.equal(b.totalCredits, 5);
  for (const v of Object.values(publicBalance({ total: 2999, gift: 2999, paid: 0 }))) {
    if (typeof v === "number") assert.ok(Number.isInteger(v), String(v));
  }
  assert.deepEqual(publicDay({ date: "2026-10-14", spent: 3, added: 0, calls: 1, balance: 2874 }), {
    date: "2026-10-14", spent: 0, added: 0, calls: 1, covered: 0, balance: 287,
  });
});

test("balance history is derived backwards from the current balance, zero-filled", () => {
  const now = new Date("2026-10-11T20:00:00Z"); // 13:00 in Vancouver
  // Stored rows, one from before the switch (whole credits) and one after (tenths).
  const rows = [
    { day: "2026-10-10", spent: 3, added: 0, calls: 1 },
    { day: "2026-10-11", spentTenths: 7, addedTenths: 20000, calls: 2 },
  ].map(rowTenths);
  const days = balanceHistory(rows, { balance: 22963, days: 3, timeZone: "America/Vancouver", now });
  assert.deepEqual(days, [
    { date: "2026-10-09", spent: 0, added: 0, calls: 0, covered: 0, balance: 3000 },
    { date: "2026-10-10", spent: 30, added: 0, calls: 1, covered: 0, balance: 2970 },
    { date: "2026-10-11", spent: 7, added: 20000, calls: 2, covered: 0, balance: 22963 },
  ]);
  assert.deepEqual(days.map(publicDay).map((d) => d.balance), [300, 297, 2296]);
});
