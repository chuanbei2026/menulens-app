// Per-user credits in DynamoDB. Nothing expires; balances only grow by grants or purchases.
//
// Unit: every amount is stored and computed as an integer number of TENTHS of a credit
// ("deci-credits": 287.4 credits = 2874). Model requests are charged to 0.1 credit, and integers keep
// thousands of small charges, refunds and DynamoDB ADDs exact — no floating-point drift. Grants,
// promotions and purchases stay whole credits (×10 when stored). Credits only become decimals
// (tenths / 10) at the API boundary; see publicBalance.
//
// Before 2026-10-14 everything was whole credits in other attribute names (giftCredits,
// paidCredits; ledger gift/paid/charged; daily spent/added). Those are read as ×10:
//   accounts  migrated in place on first use (CreditStore.migrate: conditional, keeps the old
//             values in `legacyCredits`); until then reads interpret giftCredits/paidCredits ×10
//   ledger    append-only, old entries stay as written; entryTenths reads both shapes
//   daily     a day can hold both (whole credits before the deploy, tenths after): rowTenths adds them
//
// accounts (PK userId):
//   giftTenths    granted credits ×10: 200 at signup, +100 in every month the user actually uses the service
//   paidTenths    purchased credits ×10 (App Store IAP); spent after gift credits
//   monthlyGrant  optional per-user override of the monthly grant (whole credits)
//   grantPeriod   "2026-10": the last billing month that received the monthly grant
//   subscription, subSeq   an auto-renewable subscription's state (subscription.mjs)
//   subGrantPeriod "2026-10": the last billing month that received the subscriber grant
//   coveredPeriod / coveredTenths   what the subscription covered this billing month (fair-use meter),
//                 reservations included; reset by the first covered call of a new month
//   version       optimistic-lock counter, bumped on every balance change
//   kind          "anonymous" for device accounts (anon:<uuid>); Apple accounts (apple:<sub>) have none
//   deviceSecretHash   anonymous only: SHA-256 of the device secret that renews its session
//   predecessor   anonymous only: the device account this one replaced (merged or deleted; no bonus)
//   mergedInto    a device account moved into an Apple account (merge.mjs): closed, balance 0
//   mergedFrom    an Apple account: the device accounts moved into it (their purchase tokens stay valid)
//
// ledger (PK userId, SK at): append-only record of every balance change, for support and audits:
//   { type, giftTenths, paidTenths, ref, chargedTenths? }. A call a subscription covers is a hold and a
//   settle that move nothing (chargedTenths 0) and say what the call would have cost: the hold
//   `coveredHoldTenths` (reserved), the settle `coveredTenths` (actual).
//
// usage-daily (PK userId, SK day "2026-10-11" in the billing zone): per-day rollup of the ledger —
//   spentTenths (used by model calls, net of refunds), addedTenths (grants, promotions), calls,
//   coveredTenths (what subscriber calls would have cost; not part of the balance).
//   Updated with ADD next to every ledger write, so concurrent requests never overwrite each other.
//   Daily balances are not stored: they are derived backwards from the current balance
//   (balance(d-1) = balance(d) − added(d) + spent(d)), which is always consistent. The ledger stays
//   the source of truth; scripts/rebuild-daily.mjs regenerates this table from it.
//
// promo (PK code, SK sk): small keyed records that need no table of their own. Promotion codes
//   ("#meta" / "user#<userId>") were retired in 1.1 (4): App Review counts an in-app code that adds
//   credits as unlocking paid content (3.1.1), so giveaways now use App Store Offer Codes. Old items
//   stay as history; POST /promo/redeem answers 410. Still in use here:
//   iap#<transactionId> / "#purchase"   a credited purchase (creditPurchase)
//   sub#<originalTransactionId> / "#subscription"   who owns a subscription (subscription.mjs)
//   rate#anon#<ip hash> / "h#…" | "d#…"   anonymous signups per IP (anonymous.mjs)
//
// Anonymous device accounts (anonymous.mjs) are ordinary accounts keyed "anon:<uuid>", with
// deviceSecretHash; after Sign in with Apple moves one into "apple:<sub>" it keeps only
// mergedInto (and the Apple account lists it in mergedFrom, see merge.mjs).
import { randomUUID } from "node:crypto";
import { createHash } from "node:crypto";
import { DeleteCommand, GetCommand, PutCommand, QueryCommand, TransactWriteCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { requestScope } from "./ddbstats.mjs";
import { logEvent } from "./log.mjs";
import { subscriptionActive } from "./subscription.mjs";

// --- Pure helpers (unit-tested) ------------------------------------------------------------

/** Billing month label such as "2026-10", evaluated in `timeZone`. */
export function billingPeriod(date, timeZone) {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit" }).formatToParts(date);
  const get = (t) => parts.find((p) => p.type === t).value;
  return `${get("year")}-${get("month")}`;
}

/** The label of the month after `period` ("2026-12" → "2027-01"). */
export function nextPeriod(period) {
  let [y, m] = period.split("-").map(Number);
  if (++m > 12) { m = 1; y += 1; }
  return `${y}-${String(m).padStart(2, "0")}`;
}

/** Amounts are integer tenths of a credit (see the header). */
export const TENTHS_PER_CREDIT = 10;

/** Whole (or decimal) credits → tenths, e.g. a 100-credit grant → 1000. */
export const toTenths = (credits) => Math.round(Number(credits ?? 0) * TENTHS_PER_CREDIT);

/** Tenths → credits with at most one decimal (2874 → 287.4): dividing an integer by 10 prints exactly. */
export const toCredits = (tenths) => tenths / TENTHS_PER_CREDIT;

/**
 * The luna-only formula (kept for comparison in tests): 1 credit ≈ `tokensPerCredit` input tokens,
 * output weighted `outputWeight`×, rounded up to 0.1 credit and never below 0.1. Returns tenths.
 */
export function tenthsFor(inputTokens, outputTokens, outputWeight, tokensPerCredit = 6000) {
  return Math.max(1, Math.ceil(((inputTokens + outputWeight * outputTokens) * TENTHS_PER_CREDIT) / tokensPerCredit));
}

/** An account item's balance in tenths, whether migrated (giftTenths) or still in whole credits. */
export function accountTenths(item) {
  return {
    gift: item?.giftTenths ?? toTenths(item?.giftCredits),
    paid: item?.paidTenths ?? toTenths(item?.paidCredits),
  };
}

/** A ledger entry's movement in tenths (entries before 2026-10-14 are whole credits in gift/paid). */
export function entryTenths(entry) {
  return {
    gift: entry.giftTenths ?? toTenths(entry.gift),
    paid: entry.paidTenths ?? toTenths(entry.paid),
  };
}

/** A daily rollup row in tenths: the day of the switch holds both whole-credit and tenths counters. */
export function rowTenths(row) {
  return {
    day: row.day,
    spent: (row.spentTenths ?? 0) + toTenths(row.spent),
    added: (row.addedTenths ?? 0) + toTenths(row.added),
    calls: row.calls ?? 0,
    covered: row.coveredTenths ?? 0,
  };
}

/**
 * The balance as the API reports it. Charging is exact to 0.1 credit internally, but users only ever
 * see whole credits: balances are floored (never more than the user has).
 */
export function publicBalance(b) {
  return {
    totalCredits: Math.floor(toCredits(b.total)), giftCredits: Math.floor(toCredits(b.gift)), paidCredits: Math.floor(toCredits(b.paid)),
    monthlyGrant: b.monthlyGrant, lastGrantPeriod: b.lastGrantPeriod,
  };
}

/** One day of /usage in whole credits: balance floored, spent and added rounded to the nearest. */
export function publicDay(d) {
  return {
    date: d.date, spent: Math.round(toCredits(d.spent)), added: Math.round(toCredits(d.added)), calls: d.calls,
    covered: Math.round(toCredits(d.covered ?? 0)), balance: Math.floor(toCredits(d.balance)),
  };
}

/** Calendar day ("2026-10-11") of `date` in `timeZone`. */
export function billingDay(date, timeZone) {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(date);
}

/** How a ledger entry moves the daily rollup (tenths): model calls count as spent, everything else as added. */
export function rollupDelta(entry) {
  const { gift, paid } = entryTenths(entry);
  const delta = gift + paid;
  if (entry.type === "hold") return { spent: 0 - delta, added: 0, calls: 1, covered: 0 };
  if (entry.type === "settle") return { spent: 0 - delta, added: 0, calls: 0, covered: entry.coveredTenths ?? 0 };
  return { spent: 0, added: delta, calls: 0, covered: 0 };
}

/**
 * The last `days` days ending today (zero-filled), with each day's closing balance derived backwards
 * from the current `balance`. `rows` are rollup items in tenths { day, spent, added, calls } (see
 * rowTenths); everything returned is tenths too.
 */
export function balanceHistory(rows, { balance, days, timeZone, now = new Date() }) {
  const byDay = new Map(rows.map((r) => [r.day, r]));
  const out = [];
  let closing = balance;
  for (let i = 0; i < days; i++) {
    const date = billingDay(new Date(now.getTime() - i * 86400000), timeZone);
    const r = byDay.get(date) ?? {};
    const spent = Math.max(0, r.spent ?? 0), added = r.added ?? 0;
    out.push({ date, spent, added, calls: r.calls ?? 0, covered: Math.max(0, r.covered ?? 0), balance: closing });
    closing = closing - added + spent; // the balance at the end of the previous day
  }
  return out.reverse();
}

/**
 * Upper-bound token estimate before the call (real usage arrives at the end of the stream).
 * UTF-8 bytes / 2 over-estimates both English (~4 bytes/token) and Chinese (~3 bytes/token).
 */
export function estimateInputTokens(text) {
  return Math.ceil(Buffer.byteLength(text, "utf8") / 2) + 50;
}

/** Splits a charge (tenths): gift credits first, then paid. Returns null when the balance is short. */
export function splitCharge({ gift = 0, paid = 0 }, amount) {
  const fromGift = Math.min(Math.max(gift, 0), amount);
  const fromPaid = amount - fromGift;
  return fromPaid > Math.max(paid, 0) ? null : { fromGift, fromPaid };
}

/**
 * Settles a reservation against actual usage (tenths). A refund returns to paid credits first (they cost
 * the user money), then gift; an overrun (input estimate too low) is taken from gift credits.
 */
export function settlementDeltas({ fromGift, fromPaid }, actual) {
  const reserved = fromGift + fromPaid;
  if (actual <= reserved) {
    const refund = reserved - actual;
    const toPaid = Math.min(refund, fromPaid);
    return { gift: refund - toPaid, paid: toPaid };
  }
  return { gift: -(actual - reserved), paid: 0 }; // may dip gift below zero; the next grant covers it
}

// --- DynamoDB operations -------------------------------------------------------------------

export class InsufficientCredits extends Error {
  constructor(balance) {
    super("insufficient credits");
    this.balance = balance;
  }
}

const isConditionFailure = (e) => e?.name === "ConditionalCheckFailedException";
let ledgerSeq = 0;

/** A purchase's transaction was already credited to another account. */
export class PurchaseConflict extends Error {
  constructor() {
    super("purchase belongs to another account");
    this.name = "PurchaseConflict";
  }
}

export class CreditStore {
  constructor(ddb, { accountsTable, ledgerTable, promoTable, dailyTable, monthlyGrant, signupBonus, billingTimeZone,
    subscriberMonthlyGrant = 0, subscriberMonthlyFairUse = 0 }) {
    Object.assign(this, { ddb, accountsTable, ledgerTable, promoTable, dailyTable, monthlyGrant, signupBonus, billingTimeZone,
      subscriberMonthlyGrant, subscriberMonthlyFairUse });
  }

  /**
   * Appends a ledger entry ({ type, giftTenths, paidTenths, ref, … }) without blocking the caller: inside a request the write is queued on the
   * request scope and awaited before the request finishes (so nothing is lost); outside one it is awaited.
   */
  async ledger(userId, entry) {
    const now = new Date();
    const r = rollupDelta(entry);
    const write = Promise.all([
      this.ddb.send(new PutCommand({
        TableName: this.ledgerTable,
        // Sort key: time, then a per-container sequence so entries written in the same millisecond
        // (e.g. signup + first monthly grant) keep their order, then a random tail for uniqueness.
        Item: { userId, at: `${now.toISOString()}#${String(ledgerSeq++).padStart(8, "0")}#${randomUUID().slice(0, 4)}`, ...entry },
      })),
      this.ddb.send(new UpdateCommand({
        TableName: this.dailyTable,
        Key: { userId, day: billingDay(now, this.billingTimeZone) },
        UpdateExpression: "ADD spentTenths :s, addedTenths :a, calls :c, coveredTenths :v",
        ExpressionAttributeValues: { ":s": r.spent, ":a": r.added, ":c": r.calls, ":v": r.covered },
      })),
    ]);
    const pending = requestScope.getStore()?.pending;
    if (pending) pending.push(write.catch((e) => logEvent("ERROR", "ledger write failed", { userId, entry, error: String(e) })));
    else await write;
  }

  /** Strongly consistent read of the raw account item (undefined if none). */
  async read(userId) {
    const { Item } = await this.ddb.send(new GetCommand({ TableName: this.accountsTable, Key: { userId }, ConsistentRead: true }));
    return Item;
  }

  /** The account's balance in tenths ({ total, gift, paid, … }), or null for no account. */
  toBalance(Item) {
    if (!Item) return null;
    const { gift, paid } = accountTenths(Item);
    return {
      total: Math.max(gift, 0) + Math.max(paid, 0), gift, paid,
      monthlyGrant: Item.monthlyGrant ?? this.monthlyGrant, lastGrantPeriod: Item.grantPeriod, version: Item.version ?? 0,
    };
  }

  /**
   * Moves an account still in whole credits (giftCredits / paidCredits, before 2026-10-14) to tenths,
   * once. Conditional on the version it read, so a concurrent change makes it re-read rather than
   * overwrite; the old values stay on the item in `legacyCredits`. Returns the account as it now is
   * (unchanged if already migrated or missing).
   */
  async migrate(item) {
    for (let attempt = 0; attempt < 5; attempt++) {
      if (!item || item.giftTenths !== undefined) return item;
      const { gift, paid } = accountTenths(item);
      const hasVersion = item.version !== undefined;
      try {
        const { Attributes } = await this.ddb.send(new UpdateCommand({
          TableName: this.accountsTable,
          Key: { userId: item.userId },
          UpdateExpression: "SET giftTenths = :g, paidTenths = :p, legacyCredits = :legacy, "
            + "version = if_not_exists(version, :zero) + :one REMOVE giftCredits, paidCredits",
          ConditionExpression: "attribute_exists(userId) AND attribute_not_exists(giftTenths) AND "
            + (hasVersion ? "version = :v" : "attribute_not_exists(version)"),
          ExpressionAttributeValues: {
            ":g": gift, ":p": paid, ":zero": 0, ":one": 1, ...(hasVersion ? { ":v": item.version } : {}),
            ":legacy": { giftCredits: item.giftCredits ?? 0, paidCredits: item.paidCredits ?? 0, migratedAt: new Date().toISOString() },
          },
          ReturnValues: "ALL_NEW",
        }));
        logEvent("INFO", "credits moved to tenths", { userId: item.userId, giftTenths: gift, paidTenths: paid });
        return Attributes;
      } catch (e) {
        if (!isConditionFailure(e)) throw e;
        item = await this.read(item.userId); // changed (or migrated) concurrently: look again
      }
    }
    throw new Error("credit store busy, retry later");
  }

  /**
   * Opens the account if needed (signup bonus + this month's grant), otherwise grants this month's
   * credits if the account has not received them yet. Call it when the user actually uses the service.
   *
   * Reads first, so the common case (already granted this month) costs one read and no failed writes.
   * Returns { kind: "signup" | "monthly" | "subscriber" | null, item } where `item` is the account as
   * last seen (null if a concurrent request changed it), letting the caller skip another read.
   * Active subscribers also get the subscriber grant once per billing month (subscriberGrant).
   */
  async grantIfDue(userId, now = new Date()) {
    const base = await this.baseGrant(userId, now);
    if (!base.item || !subscriptionActive(base.item.subscription, now)) return base;
    return (await this.subscriberGrant(userId, base.item, now)) ?? base;
  }

  /** The signup bonus and the everyone-monthly grant (0 for ForeignMenu). */
  async baseGrant(userId, now) {
    const period = billingPeriod(now, this.billingTimeZone);
    let item = await this.migrate(await this.read(userId));
    if (item && item.grantPeriod >= period) return { kind: null, item };

    if (!item) {
      // Someone who deleted their account and signs in again starts from zero: no second signup bonus.
      const reopened = Boolean(await this.read(CreditStore.tombstoneKey(userId)));
      item = { userId, giftTenths: reopened ? 0 : toTenths(this.signupBonus + this.monthlyGrant), paidTenths: 0, grantPeriod: period,
               createdAt: now.toISOString(), version: 1, ...(reopened ? { reopened: true } : {}) };
      try {
        await this.ddb.send(new PutCommand({ TableName: this.accountsTable, Item: item, ConditionExpression: "attribute_not_exists(userId)" }));
        if (reopened) return { kind: "reopen", item };
        await this.ledger(userId, { type: "signup", giftTenths: toTenths(this.signupBonus), paidTenths: 0, ref: period });
        if (this.monthlyGrant > 0) await this.ledger(userId, { type: "monthly_grant", giftTenths: toTenths(this.monthlyGrant), paidTenths: 0, ref: period });
        return { kind: "signup", item };
      } catch (e) {
        if (!isConditionFailure(e)) throw e;
        return { kind: null, item: null }; // a concurrent request opened it first
      }
    }
    // The per-user override is whole credits and DynamoDB can't multiply, so the grant is computed
    // here and the write is conditional on the override not having changed since the read.
    const grant = toTenths(item.monthlyGrant ?? this.monthlyGrant);
    // No monthly grant (ForeignMenu: 300 at signup, then purchases): nothing to write, ever.
    if (grant === 0) return { kind: null, item };
    const sameOverride = item.monthlyGrant === undefined ? "attribute_not_exists(monthlyGrant)" : "monthlyGrant = :override";
    try {
      const { Attributes: a } = await this.ddb.send(new UpdateCommand({
        TableName: this.accountsTable,
        Key: { userId },
        UpdateExpression: "SET giftTenths = giftTenths + :grant, "
          + "grantPeriod = :period, lastGrantAt = :now, version = if_not_exists(version, :zero) + :one",
        // Still conditional: two concurrent first-of-month requests must not both grant.
        ConditionExpression: "(attribute_not_exists(grantPeriod) OR grantPeriod < :period) AND attribute_exists(giftTenths) AND " + sameOverride,
        ExpressionAttributeValues: { ":grant": grant, ":zero": 0, ":one": 1, ":period": period, ":now": now.toISOString(),
          ...(item.monthlyGrant === undefined ? {} : { ":override": item.monthlyGrant }) },
        ReturnValues: "ALL_NEW",
      }));
      await this.ledger(userId, { type: "monthly_grant", giftTenths: grant, paidTenths: 0, ref: period });
      return { kind: "monthly", item: a };
    } catch (e) {
      if (isConditionFailure(e)) return { kind: null, item: null }; // granted concurrently
      throw e;
    }
  }

  /**
   * Gives an active subscriber `subscriberMonthlyGrant` gift credits, once per billing month (its own
   * marker, so it doesn't depend on when the account was opened). Returns { kind: "subscriber", item }
   * when granted, null when there is nothing to do, { kind: null, item: null } when a concurrent
   * request granted first.
   */
  async subscriberGrant(userId, item, now = new Date()) {
    const period = billingPeriod(now, this.billingTimeZone);
    const grant = toTenths(this.subscriberMonthlyGrant);
    if (grant <= 0 || item.subGrantPeriod >= period) return null;
    try {
      const { Attributes } = await this.ddb.send(new UpdateCommand({
        TableName: this.accountsTable, Key: { userId },
        UpdateExpression: "SET giftTenths = giftTenths + :grant, subGrantPeriod = :period, version = if_not_exists(version, :zero) + :one",
        ConditionExpression: "(attribute_not_exists(subGrantPeriod) OR subGrantPeriod < :period) AND attribute_exists(giftTenths)",
        ExpressionAttributeValues: { ":grant": grant, ":period": period, ":zero": 0, ":one": 1 },
        ReturnValues: "ALL_NEW",
      }));
      await this.ledger(userId, { type: "subscriber_grant", giftTenths: grant, paidTenths: 0, ref: period });
      return { kind: "subscriber", item: Attributes };
    } catch (e) {
      if (isConditionFailure(e)) return { kind: null, item: null };
      throw e;
    }
  }

  /**
   * For an active subscriber with room left under this month's fair use: reserves `amount` tenths
   * against the covered-usage counter instead of the balance. Race-safe like reserve: the counter only
   * grows through a conditional update, so concurrent calls can't together pass the cap.
   * Returns { split: { fromGift: 0, fromPaid: 0, covered, period } } or { split: null, reason } with
   * reason "inactive" (no active subscription; charge normally) or "fair_use" (over the cap).
   */
  async reserveCovered(userId, amount, ref, known = null, now = new Date()) {
    const period = billingPeriod(now, this.billingTimeZone);
    const cap = toTenths(this.subscriberMonthlyFairUse);
    for (let attempt = 0; attempt < 5; attempt++) {
      const item = attempt === 0 && known ? known : await this.read(userId);
      if (!item || !subscriptionActive(item.subscription, now)) return { split: null, reason: "inactive" };
      const sameMonth = item.coveredPeriod === period;
      if ((sameMonth ? item.coveredTenths ?? 0 : 0) + amount > cap) return { split: null, reason: "fair_use" };
      try {
        await this.ddb.send(new UpdateCommand(sameMonth ? {
          TableName: this.accountsTable, Key: { userId },
          UpdateExpression: "SET coveredTenths = coveredTenths + :a",
          ConditionExpression: "coveredPeriod = :p AND coveredTenths <= :room",
          ExpressionAttributeValues: { ":a": amount, ":p": period, ":room": cap - amount },
        } : {
          TableName: this.accountsTable, Key: { userId },
          UpdateExpression: "SET coveredPeriod = :p, coveredTenths = :a",
          ConditionExpression: "attribute_exists(userId) AND (attribute_not_exists(coveredPeriod) OR coveredPeriod < :p)",
          ExpressionAttributeValues: { ":a": amount, ":p": period },
        }));
        await this.ledger(userId, { type: "hold", giftTenths: 0, paidTenths: 0, coveredHoldTenths: amount, ref });
        return { split: { fromGift: 0, fromPaid: 0, covered: amount, period } };
      } catch (e) {
        if (!isConditionFailure(e)) throw e; // another call moved the counter (or the month): look again
      }
    }
    logEvent("ERROR", "covered reserve gave up after retries", { userId, ref });
    throw new Error("credit store busy, retry later");
  }

  /** Current balance, or null for an account that has never used the service. */
  async balance(userId) {
    return this.toBalance(await this.read(userId));
  }

  /**
   * Atomically takes `amount` tenths (gift first, then paid) with optimistic locking; retries on
   * contention. The version condition means two concurrent requests can never both spend the same
   * balance. `known` is an account item the caller just read; the first attempt uses it instead of
   * reading again.
   */
  async reserve(userId, amount, ref, known = null) {
    for (let attempt = 0; attempt < 5; attempt++) {
      const item = await this.migrate(attempt === 0 && known ? known : await this.read(userId));
      const b = this.toBalance(item) ?? { total: 0, gift: 0, paid: 0, monthlyGrant: this.monthlyGrant, version: 0 };
      const split = item ? splitCharge(b, amount) : null;
      if (!split) throw new InsufficientCredits(b);
      try {
        await this.ddb.send(new UpdateCommand({
          TableName: this.accountsTable,
          Key: { userId },
          UpdateExpression: "SET giftTenths = giftTenths - :g, paidTenths = paidTenths - :p, version = version + :one",
          ConditionExpression: "version = :v AND attribute_exists(giftTenths)",
          ExpressionAttributeValues: { ":g": split.fromGift, ":p": split.fromPaid, ":v": b.version, ":one": 1 },
        }));
        await this.ledger(userId, { type: "hold", giftTenths: -split.fromGift, paidTenths: -split.fromPaid, ref });
        if (attempt > 0) logEvent("WARN", "credit reserve contention", { userId, ref, retries: attempt });
        return split;
      } catch (e) {
        if (!isConditionFailure(e)) throw e; // someone else changed the balance → re-read and retry
      }
    }
    logEvent("ERROR", "credit reserve gave up after retries", { userId, ref });
    throw new Error("credit store busy, retry later");
  }

  /**
   * Applies the difference between the reservation and `actual` usage, both tenths (no version
   * condition: integer deltas commute; reserve already moved the account to tenths).
   */
  async settle(userId, split, actual, ref) {
    if (split.covered !== undefined) return this.settleCovered(userId, split, actual, ref);
    const d = settlementDeltas(split, actual);
    if (d.gift !== 0 || d.paid !== 0) {
      await this.ddb.send(new UpdateCommand({
        TableName: this.accountsTable,
        Key: { userId },
        UpdateExpression: "SET giftTenths = giftTenths + :g, paidTenths = paidTenths + :p, version = version + :one",
        ExpressionAttributeValues: { ":g": d.gift, ":p": d.paid, ":one": 1 },
      }));
    }
    await this.ledger(userId, { type: "settle", giftTenths: d.gift, paidTenths: d.paid, ref, chargedTenths: actual });
    return d;
  }

  /**
   * Settles a covered reservation: the counter moves by actual − reserved (a failed call gives it all
   * back), the balance doesn't move, and the ledger records chargedTenths 0 with what was covered.
   * If the month rolled over meanwhile the old month's counter is gone and there is nothing to adjust.
   */
  async settleCovered(userId, split, actual, ref) {
    const d = actual - split.covered;
    if (d !== 0) {
      try {
        await this.ddb.send(new UpdateCommand({
          TableName: this.accountsTable, Key: { userId },
          UpdateExpression: "SET coveredTenths = coveredTenths + :d",
          ConditionExpression: "coveredPeriod = :p",
          ExpressionAttributeValues: { ":d": d, ":p": split.period },
        }));
      } catch (e) {
        if (!isConditionFailure(e)) throw e;
      }
    }
    await this.ledger(userId, { type: "settle", giftTenths: 0, paidTenths: 0, ref, chargedTenths: 0, coveredTenths: actual });
    return { gift: 0, paid: 0 };
  }

  /**
   * Credits a verified in-app purchase once per transaction: a marker item in the promo table
   * (`code = iap#<transactionId>`, so no new table or permission is needed) and the paid credits
   * are written in one transaction (the account must be in tenths: call grantIfDue first). Returns { credited, credits } — credited is false when the
   * transaction was already applied (the app retries until it can finish the transaction).
   */
  async creditPurchase(userId, { transactionId, productId, credits, environment }, now = new Date()) {
    try {
      await this.ddb.send(new TransactWriteCommand({ TransactItems: [
        { Put: {
          TableName: this.promoTable,
          Item: { code: `iap#${transactionId}`, sk: "#purchase", userId, productId, credits, environment, at: now.toISOString() },
          ConditionExpression: "attribute_not_exists(code)",
        } },
        { Update: {
          TableName: this.accountsTable, Key: { userId },
          UpdateExpression: "SET paidTenths = if_not_exists(paidTenths, :zero) + :c, version = version + :one",
          ConditionExpression: "attribute_exists(userId) AND attribute_exists(giftTenths)",
          ExpressionAttributeValues: { ":c": toTenths(credits), ":zero": 0, ":one": 1 },
        } },
      ] }));
    } catch (e) {
      if (e?.name !== "TransactionCanceledException") throw e;
      const [marker] = (e.CancellationReasons ?? []).map((r) => r?.Code);
      if (marker === "ConditionalCheckFailed") {
        // Already applied — only to this user; a different user would be someone replaying a receipt.
        const { Item } = await this.ddb.send(new GetCommand({ TableName: this.promoTable, Key: { code: `iap#${transactionId}`, sk: "#purchase" } }));
        // Credited to a device account that has since moved into this one (merge.mjs) is ours too.
        if (Item?.userId !== userId && (await this.read(Item?.userId ?? "-"))?.mergedInto !== userId) throw new PurchaseConflict();
        return { credited: false, credits: Item.credits };
      }
      throw e;
    }
    await this.ledger(userId, { type: "purchase", giftTenths: 0, paidTenths: toTenths(credits), ref: `${productId}#${transactionId}` });
    return { credited: true, credits };
  }

  /**
   * Opens a new account with `bonus` whole credits as gifts and `fields` (anonymous.mjs: kind,
   * deviceSecretHash, predecessor). Fails with ConditionalCheckFailedException if the id is taken.
   * The ledger gets a signup entry only when there is a bonus.
   */
  async openAccount(userId, { bonus, fields = {} }, now = new Date()) {
    const period = billingPeriod(now, this.billingTimeZone);
    const item = { userId, giftTenths: toTenths(bonus), paidTenths: 0, grantPeriod: period, createdAt: now.toISOString(), version: 1, ...fields };
    await this.ddb.send(new PutCommand({ TableName: this.accountsTable, Item: item, ConditionExpression: "attribute_not_exists(userId)" }));
    if (bonus > 0) await this.ledger(userId, { type: "signup", giftTenths: toTenths(bonus), paidTenths: 0, ref: period });
    return item;
  }

  /** Whether `userId` deleted an account before (the hashed tombstone deleteAccount leaves). */
  async wasDeleted(userId) {
    return Boolean(await this.read(CreditStore.tombstoneKey(userId)));
  }

  /** Keeps the Sign in with Apple refresh token on the account (for revocation on deletion). */
  async setAppleRefreshToken(userId, token) {
    await this.ddb.send(new UpdateCommand({
      TableName: this.accountsTable, Key: { userId },
      UpdateExpression: "SET appleRefreshToken = :t", ConditionExpression: "attribute_exists(userId)",
      ExpressionAttributeValues: { ":t": token },
    }));
  }

  async appleRefreshToken(userId) {
    return (await this.read(userId))?.appleRefreshToken ?? null;
  }

  /** Accounts-table key remembering that a user deleted their account (hashed: no user id kept). */
  static tombstoneKey(userId) {
    return `deleted#${createHash("sha256").update(userId).digest("hex")}`;
  }

  /**
   * Deletes the account (balance, nickname, avatar key) and its daily usage rows. The ledger stays:
   * it is the financial record of purchases and charges. A hashed tombstone stops a fresh signup bonus.
   */
  async deleteAccount(userId, now = new Date()) {
    await this.ddb.send(new PutCommand({ TableName: this.accountsTable, Item: { userId: CreditStore.tombstoneKey(userId), deletedAt: now.toISOString() } }));
    await this.ddb.send(new DeleteCommand({ TableName: this.accountsTable, Key: { userId } }));
    let start;
    do {
      const r = await this.ddb.send(new QueryCommand({
        TableName: this.dailyTable, KeyConditionExpression: "userId = :u", ExpressionAttributeValues: { ":u": userId },
        ProjectionExpression: "userId, #d", ExpressionAttributeNames: { "#d": "day" }, ExclusiveStartKey: start,
      }));
      for (const row of r.Items ?? []) {
        await this.ddb.send(new DeleteCommand({ TableName: this.dailyTable, Key: { userId: row.userId, day: row.day } }));
      }
      start = r.LastEvaluatedKey;
    } while (start);
  }

  /** Rollup rows of the last `days` days in tenths (see rowTenths), for the balance-history chart. */
  async dailyRows(userId, days, now = new Date()) {
    const since = billingDay(new Date(now.getTime() - days * 86400000), this.billingTimeZone);
    const { Items } = await this.ddb.send(new QueryCommand({
      TableName: this.dailyTable,
      KeyConditionExpression: "userId = :u AND #d >= :since",
      ExpressionAttributeNames: { "#d": "day" },
      ExpressionAttributeValues: { ":u": userId, ":since": since },
    }));
    return (Items ?? []).map(rowTenths);
  }
}
