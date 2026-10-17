// Auto-renewable subscriptions ("ForeignMenu Membership"): monthly / quarterly / yearly in one group.
// While a subscription is active, menu scans and dish pictures are covered instead of charged, up to
// a fair-use amount of credits per billing month (CreditStore.reserveCovered), and the account gets a
// small monthly grant (CreditStore.grantIfDue). Everything else about credits is unchanged.
//
// Where the state comes from (both verified with verifyAppleJWS, Apple's pinned root):
//   POST /subscription { jws, renewalJws? }   the app's current entitlement, after a purchase and on
//                                             every launch / return to the foreground
//   POST /appstore/notifications              App Store Server Notifications V2 ({ signedPayload }),
//                                             renewals, expiry, billing problems, refunds
//
// accounts (PK userId), next to the balance:
//   subscription  { productId, originalTransactionId, transactionId, expiresAt, graceExpiresAt?,
//                   autoRenew?, environment, revokedAt?, status?, renewalSignedAt?, lastVerifiedAt }
//   subSeq        optimistic-lock counter for `subscription` only (balance changes don't touch it)
//   subGrantPeriod / coveredPeriod / coveredTenths   see credits.mjs
// promo (PK code, SK sk): `sub#<originalTransactionId>` / "#subscription" → { userId }: which account
//   a subscription belongs to, for notifications (which carry no user) and so one Apple subscription
//   can't be claimed by a second account.

import { GetCommand, PutCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { accountToken, PurchaseError } from "./purchase.mjs";
import { logEvent } from "./log.mjs";

/** The subscription products (one group). Prices live in App Store Connect: US$4 / 10 / 30. */
export const SUBSCRIPTIONS = {
  "ai.xiangyang.MenuLens.sub.monthly": { months: 1 },
  "ai.xiangyang.MenuLens.sub.quarterly": { months: 3 },
  "ai.xiangyang.MenuLens.sub.yearly": { months: 12 },
};

const iso = (ms) => (typeof ms === "number" && Number.isFinite(ms) ? new Date(ms).toISOString() : undefined);
const time = (s) => (s ? Date.parse(s) || 0 : 0);
const compact = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && v !== null));

/** Whether `sub` (the stored state) gives access at `now`: not revoked, and before expiry or the grace period's end. */
export function subscriptionActive(sub, now = new Date()) {
  if (!sub || sub.revokedAt) return false;
  return now.getTime() < Math.max(time(sub.expiresAt), time(sub.graceExpiresAt));
}

/**
 * Checks a verified transaction payload (JWSTransactionDecodedPayload) for one of our subscriptions and
 * returns the facts we keep. `userId` (when known) must match the appAccountToken the purchase carries.
 */
export function subscriptionTransaction(payload, { userId, bundleId, allowSandbox }) {
  if (payload.bundleId !== bundleId) throw new PurchaseError("wrong_app");
  if (!SUBSCRIPTIONS[payload.productId]) throw new PurchaseError("unknown_product");
  if (payload.type && payload.type !== "Auto-Renewable Subscription") throw new PurchaseError("unknown_product");
  const env = payload.environment;
  if (env !== "Production" && !(allowSandbox && env === "Sandbox")) throw new PurchaseError("wrong_environment");
  if (userId && payload.appAccountToken && payload.appAccountToken.toLowerCase() !== accountToken(userId)) {
    throw new PurchaseError("wrong_account");
  }
  for (const k of ["transactionId", "originalTransactionId"]) {
    if (typeof payload[k] !== "string" || !payload[k]) throw new PurchaseError("bad_jws");
  }
  const expiresAt = iso(payload.expiresDate);
  if (!expiresAt) throw new PurchaseError("bad_jws");
  return compact({
    productId: payload.productId, transactionId: payload.transactionId, originalTransactionId: payload.originalTransactionId,
    expiresAt, environment: env, revokedAt: iso(payload.revocationDate),
  });
}

/** The facts we keep from a verified renewal info payload (JWSRenewalInfoDecodedPayload). */
export function renewalFacts(payload) {
  return compact({
    originalTransactionId: payload.originalTransactionId,
    autoRenew: payload.autoRenewStatus === undefined ? undefined : payload.autoRenewStatus === 1,
    autoRenewProductId: payload.autoRenewProductId,
    graceExpiresAt: iso(payload.gracePeriodExpiresDate),
    signedAt: iso(payload.signedDate) ?? new Date(0).toISOString(),
  });
}

/**
 * The stored state after `incoming` ({ ...subscriptionTransaction, renewal?, status? }) — pure, and
 * order-independent enough for notifications that arrive late or twice:
 *   - the transaction that runs longest wins (an old renewal never shortens access);
 *   - a revocation applies when it is for the current transaction (refund / Family Sharing revoked);
 *     a later new transaction (resubscribing) clears it;
 *   - renewal info (auto-renew, grace period) only replaces older renewal info;
 *   - a different subscription (another Apple ID) replaces an active one only if it runs longer.
 */
export function mergeSubscription(current, incoming, now = new Date()) {
  let next;
  if (current && current.originalTransactionId === incoming.originalTransactionId) {
    next = { ...current };
  } else {
    if (current && subscriptionActive(current, now) && time(incoming.expiresAt) <= time(current.expiresAt)) return current;
    next = {};
  }
  if (incoming.transactionId) {
    const runsLonger = !next.expiresAt || time(incoming.expiresAt) >= time(next.expiresAt);
    if (runsLonger) {
      if (incoming.transactionId !== next.transactionId) delete next.revokedAt;
      Object.assign(next, {
        productId: incoming.productId, transactionId: incoming.transactionId,
        originalTransactionId: incoming.originalTransactionId, expiresAt: incoming.expiresAt, environment: incoming.environment,
      });
      // A renewal past the grace period ends it.
      if (time(next.graceExpiresAt) <= time(next.expiresAt)) delete next.graceExpiresAt;
    }
    if (incoming.revokedAt && incoming.transactionId === next.transactionId) next.revokedAt = incoming.revokedAt;
  }
  const r = incoming.renewal;
  if (r && (!next.renewalSignedAt || r.signedAt >= next.renewalSignedAt)) {
    next.renewalSignedAt = r.signedAt;
    if (r.autoRenew !== undefined) next.autoRenew = r.autoRenew;
    if (r.graceExpiresAt && time(r.graceExpiresAt) > time(next.expiresAt)) next.graceExpiresAt = r.graceExpiresAt;
    else delete next.graceExpiresAt;
  }
  if (incoming.status) next.status = incoming.status;
  next.lastVerifiedAt = now.toISOString();
  return next;
}

/** What GET /credits and /usage report: whole credits, ISO dates. */
export function publicSubscription(item, { now = new Date(), period, fairUseCredits }) {
  const sub = item?.subscription;
  const usedTenths = item?.coveredPeriod === period ? Math.max(0, item.coveredTenths ?? 0) : 0;
  const active = subscriptionActive(sub, now);
  return {
    active,
    productId: sub?.productId ?? null,
    // During a billing grace period access runs to its end.
    expiresAt: sub ? (active && time(sub.graceExpiresAt) > time(sub.expiresAt) ? sub.graceExpiresAt : sub.expiresAt) : null,
    autoRenew: sub?.autoRenew ?? null,
    monthUsedCredits: Math.round(usedTenths / 10),
    monthFairUseCredits: fairUseCredits,
  };
}

const isConditionFailure = (e) => e?.name === "ConditionalCheckFailedException";

/** A subscription is already linked to another account. */
export class SubscriptionConflict extends Error {
  constructor() {
    super("subscription belongs to another account");
    this.name = "SubscriptionConflict";
  }
}

export class SubscriptionStore {
  constructor(ddb, { accountsTable, promoTable }) {
    Object.assign(this, { ddb, accountsTable, promoTable });
  }

  static linkKey(originalTransactionId) {
    return { code: `sub#${originalTransactionId}`, sk: "#subscription" };
  }

  /** Links an Apple subscription to `userId` (idempotent); throws SubscriptionConflict if it is someone else's. */
  async link(userId, originalTransactionId, now = new Date()) {
    try {
      await this.ddb.send(new PutCommand({
        TableName: this.promoTable,
        Item: { ...SubscriptionStore.linkKey(originalTransactionId), userId, at: now.toISOString() },
        ConditionExpression: "attribute_not_exists(code) OR userId = :u",
        ExpressionAttributeValues: { ":u": userId },
      }));
    } catch (e) {
      if (isConditionFailure(e)) throw new SubscriptionConflict();
      throw e;
    }
  }

  /** The account a subscription belongs to, or null. */
  async ownerOf(originalTransactionId) {
    const { Item } = await this.ddb.send(new GetCommand({ TableName: this.promoTable, Key: SubscriptionStore.linkKey(originalTransactionId) }));
    return Item?.userId ?? null;
  }

  /**
   * Merges `incoming` into the account's subscription (see mergeSubscription), conditional on nobody
   * else having changed it since the read. Returns { before, after, item } or null when the account
   * doesn't exist (deleted).
   */
  async apply(userId, incoming, now = new Date()) {
    for (let attempt = 0; attempt < 5; attempt++) {
      const { Item } = await this.ddb.send(new GetCommand({ TableName: this.accountsTable, Key: { userId }, ConsistentRead: true }));
      if (!Item) return null;
      const before = Item.subscription;
      const after = mergeSubscription(before, incoming, now);
      const seq = Item.subSeq;
      try {
        const { Attributes } = await this.ddb.send(new UpdateCommand({
          TableName: this.accountsTable, Key: { userId },
          UpdateExpression: "SET subscription = :s, subSeq = :next",
          ConditionExpression: "attribute_exists(userId) AND " + (seq === undefined ? "attribute_not_exists(subSeq)" : "subSeq = :seq"),
          ExpressionAttributeValues: { ":s": after, ":next": (seq ?? 0) + 1, ...(seq === undefined ? {} : { ":seq": seq }) },
          ReturnValues: "ALL_NEW",
        }));
        return { before, after, item: Attributes };
      } catch (e) {
        if (!isConditionFailure(e)) throw e;
      }
    }
    throw new Error("subscription store busy, retry later");
  }
}

/**
 * POST /subscription: the app's current entitlement ({ jws, renewalJws? }) for `userId`. Verified and
 * checked like a purchase, linked to this account (SubscriptionConflict if it is another's), merged
 * into its state, recorded in the purchases table when the transaction is new to us. Idempotent: the
 * app sends it on every launch. `grant(userId)` runs before (opens a new account) and after (the first
 * use in a month while subscribed brings the subscriber grant) and returns the account item.
 * Throws PurchaseError / SubscriptionConflict with `payload` attached (for the rejected record).
 * Returns { item, after, isNew, productId, payload }.
 */
export async function recordEntitlement({ jws, renewalJws } = {}, deps, now = new Date()) {
  const { userId, verify, subs, records, grant, read, bundleId, allowSandbox } = deps;
  let payload = null;
  try {
    payload = verify(jws);
    const tx = subscriptionTransaction(payload, { userId, bundleId, allowSandbox });
    if (tx.revokedAt) throw new PurchaseError("revoked");
    const incoming = { ...tx, status: "app" };
    if (typeof renewalJws === "string" && renewalJws) {
      try {
        const r = verify(renewalJws);
        if (r.originalTransactionId === tx.originalTransactionId) incoming.renewal = renewalFacts(r);
      } catch (e) {
        logEvent("WARN", "renewal info rejected", { userId, reason: e.reason ?? String(e.message) });
      }
    }
    await grant(userId);
    await subs.link(userId, tx.originalTransactionId, now);
    const applied = await subs.apply(userId, incoming, now);
    if (!applied) throw new Error("account missing after opening it");
    const isNew = applied.before?.transactionId !== tx.transactionId;
    if (isNew) await records?.record(userId, subscriptionRecord(payload, "active", "app"), now);
    const item = (await grant(userId)) ?? await read(userId);
    return { item, after: applied.after, isNew, productId: tx.productId, payload };
  } catch (e) {
    if (e instanceof PurchaseError || e instanceof SubscriptionConflict) e.payload = payload;
    throw e;
  }
}

/** Notification types that put a new transaction on the books (recorded in the purchases table). */
const NEW_TRANSACTION = new Set(["SUBSCRIBED", "DID_RENEW"]);
const REVOKING = new Set(["REFUND", "REVOKE"]);

/**
 * Handles one App Store Server Notification V2 body. Never throws: Apple retries anything but a 2xx,
 * and nothing in a notification is worth a retry storm, so problems are logged and answered 200.
 * `deps`: { verify, subs, records, bundleId, allowSandbox, onApplied?(userId, after) }.
 * Returns a short summary for the request log.
 */
export async function handleNotification(body, deps, now = new Date()) {
  const { verify, subs, records, bundleId, allowSandbox } = deps;
  const out = {};
  try {
    const n = verify(body?.signedPayload);
    Object.assign(out, { type: n.notificationType, subtype: n.subtype });
    const data = n.data ?? {};
    if (data.bundleId !== bundleId) return { ...out, ignored: "wrong_app" };
    if (data.environment === "Sandbox" && !allowSandbox) return { ...out, ignored: "sandbox" };
    if (!data.signedTransactionInfo) return { ...out, ignored: "no_transaction" }; // TEST, summaries
    const tx = verify(data.signedTransactionInfo);
    out.productId = tx.productId;
    if (!SUBSCRIPTIONS[tx.productId]) {
      // Credit packs (e.g. a REFUND of a consumable): logged for support, nothing to change here.
      return { ...out, ignored: "not_a_subscription" };
    }
    const renewalPayload = data.signedRenewalInfo ? verify(data.signedRenewalInfo) : null;
    const userId = await subs.ownerOf(tx.originalTransactionId);
    if (!userId) {
      logEvent("WARN", "notification for an unknown subscription", { type: out.type, originalTransactionId: tx.originalTransactionId });
      return { ...out, ignored: "unknown_subscription" };
    }
    out.userId = userId;
    const incoming = subscriptionTransaction(tx, { userId, bundleId, allowSandbox });
    if (REVOKING.has(n.notificationType) && !incoming.revokedAt) incoming.revokedAt = iso(n.signedDate) ?? now.toISOString();
    if (renewalPayload?.originalTransactionId === tx.originalTransactionId) incoming.renewal = renewalFacts(renewalPayload);
    incoming.status = [n.notificationType, n.subtype].filter(Boolean).join(":");
    const applied = await subs.apply(userId, incoming, now);
    if (!applied) return { ...out, ignored: "account_deleted" };
    const isNew = applied.before?.transactionId !== incoming.transactionId;
    if ((NEW_TRANSACTION.has(n.notificationType) && isNew) || REVOKING.has(n.notificationType)) {
      await records?.record(userId, subscriptionRecord(tx, REVOKING.has(n.notificationType) ? "refunded" : "active", out.type), now);
    }
    out.active = subscriptionActive(applied.after, now);
    out.expiresAt = applied.after.expiresAt;
    return out;
  } catch (e) {
    const reason = e instanceof PurchaseError ? e.reason : String(e?.message ?? e);
    logEvent("WARN", "notification not applied", { type: out.type, reason });
    return { ...out, ignored: reason };
  }
}

/** A purchases-table entry for a subscription transaction (see purchaseRecords.mjs). */
export function subscriptionRecord(payload, status, source) {
  return compact({
    type: "subscription", status, source,
    transactionId: payload.transactionId, originalTransactionId: payload.originalTransactionId, productId: payload.productId,
    price: typeof payload.price === "number" ? payload.price / 1000 : undefined, currency: payload.currency,
    storefront: payload.storefront, environment: payload.environment,
    purchaseDate: iso(payload.purchaseDate), expiresDate: iso(payload.expiresDate),
    offerType: payload.offerType, revocationDate: iso(payload.revocationDate),
  });
}
