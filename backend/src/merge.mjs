// Sign in with Apple while on a device account (POST /auth/apple/link): the device account moves
// into the Apple account "apple:<sub>", which is created for it when the Apple ID is new.
//
//   Apple ID new       "attach": apple:<sub> is opened with the device account's balance and
//                      subscription, and no signup bonus (the device account already had it).
//   Apple ID existing  "merge":  the device account's balance is added to apple:<sub>; its
//                      subscription is taken when it runs longer than the Apple account's.
//
// Either way the same steps, so there is one path to get right:
//   1. one DynamoDB transaction moves the money: the device account is closed (balance 0,
//      mergedInto = apple:<sub>), the Apple account gains the balance and lists the device account
//      in mergedFrom, and both ledgers and daily rollups record it (merge_out / merge_in).
//      Conditional on both accounts' versions, so a concurrent charge or a second tap makes it
//      re-read and try again instead of moving a stale balance;
//   2. then, outside the transaction and each step idempotent: subscription links
//      (sub#<originalTransactionId>), credited-purchase markers (iap#<transactionId>) and the
//      purchases-table rows are re-pointed to the Apple account, and the device account's daily rows
//      are dropped.
// A retry (the app didn't get the answer, or step 2 was cut off) finds mergedInto already set and
// just runs step 2 again; a later charge that settled into the closed account is swept the same way.
// Nothing here can double-count: step 1 happens once per balance it sees, step 2 only re-points.
//
// The device account's transactions keep its appAccountToken forever (StoreKit fixes it at
// purchase), so the Apple account accepts the tokens of everything in mergedFrom (purchase.mjs).

import { randomUUID } from "node:crypto";
import { DeleteCommand, QueryCommand, TransactWriteCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { accountTenths, billingDay, billingPeriod } from "./credits.mjs";
import { subscriptionActive } from "./subscription.mjs";

export class MergeError extends Error {
  /** reason: "no_account" (deleted) | "conflict" (already moved into another Apple account) */
  constructor(reason) {
    super(reason);
    this.reason = reason;
  }
}

const time = (s) => (s ? Date.parse(s) || 0 : 0);

/** The subscription the Apple account should end up with, or null to leave its own. */
export function pickSubscription(target, incoming, now = new Date()) {
  if (!incoming) return null;
  if (!target) return incoming;
  if (!subscriptionActive(incoming, now)) return null;
  if (subscriptionActive(target, now) && time(target.expiresAt) >= time(incoming.expiresAt)) return null;
  return incoming;
}

/**
 * Moves `anonId` into `appleId`. `deps`: { ddb, store (CreditStore), subs (SubscriptionStore),
 * purchases (PurchaseRecords), config }. Returns { kind: "attach" | "merge" | "already",
 * movedTenths }.
 */
export async function mergeIntoApple(anonId, appleId, deps, now = new Date()) {
  const { store } = deps;
  let kind = null, movedTenths = 0;
  for (let attempt = 0; attempt < 6; attempt++) {
    const anon = await store.migrate(await store.read(anonId));
    if (!anon) throw new MergeError("no_account");
    if (anon.mergedInto && anon.mergedInto !== appleId) throw new MergeError("conflict");
    const { gift, paid } = accountTenths(anon);
    if (anon.mergedInto && gift === 0 && paid === 0) break; // moved already (a retry): only step 2 left
    const target = await store.migrate(await store.read(appleId));
    try {
      await deps.ddb.send(new TransactWriteCommand({ TransactItems: moveItems(anon, target, appleId, { gift, paid }, deps.config, now) }));
      kind ??= target ? "merge" : "attach";
      movedTenths += gift + paid;
    } catch (e) {
      if (e?.name !== "TransactionCanceledException") throw e;
      // An account changed between the read and the write (a charge, a concurrent link): look again.
      if (attempt === 5) throw new Error("account busy, retry later");
    }
  }
  await repoint(anonId, appleId, deps);
  return { kind: kind ?? "already", movedTenths };
}

/** Step 1's transaction (see the header). */
function moveItems(anon, target, appleId, { gift, paid }, config, now) {
  const anonId = anon.userId;
  const iso = now.toISOString();
  const day = billingDay(now, config.billingTimeZone);
  const tail = `${String(anon.version ?? 0).padStart(8, "0")}#${randomUUID().slice(0, 4)}`;
  const sub = anon.mergedInto ? null : pickSubscription(target?.subscription, anon.subscription, now);
  const mergedFrom = [...new Set([...(target?.mergedFrom ?? []), anonId])];
  const items = [{ Update: {
    TableName: config.accountsTable, Key: { userId: anonId },
    UpdateExpression: "SET giftTenths = :zero, paidTenths = :zero, mergedInto = :apple, mergedAt = :now, version = version + :one",
    ConditionExpression: "version = :v AND (attribute_not_exists(mergedInto) OR mergedInto = :apple)",
    ExpressionAttributeValues: { ":zero": 0, ":apple": appleId, ":now": iso, ":one": 1, ":v": anon.version },
  } }];
  if (target) {
    const subSet = sub ? ", subscription = :s, subSeq = :seqNext" : "";
    const subCondition = !sub ? "" : target.subSeq === undefined ? " AND attribute_not_exists(subSeq)" : " AND subSeq = :seq";
    items.push({ Update: {
      TableName: config.accountsTable, Key: { userId: appleId },
      UpdateExpression: `SET giftTenths = giftTenths + :g, paidTenths = paidTenths + :p, mergedFrom = :from, version = version + :one${subSet}`,
      ConditionExpression: `version = :v AND attribute_exists(giftTenths)${subCondition}`,
      ExpressionAttributeValues: {
        ":g": gift, ":p": paid, ":from": mergedFrom, ":one": 1, ":v": target.version,
        ...(sub ? { ":s": sub, ":seqNext": (target.subSeq ?? 0) + 1 } : {}),
        ...(sub && target.subSeq !== undefined ? { ":seq": target.subSeq } : {}),
      },
    } });
  } else {
    items.push({ Put: {
      TableName: config.accountsTable,
      Item: {
        userId: appleId, giftTenths: gift, paidTenths: paid, grantPeriod: billingPeriod(now, config.billingTimeZone),
        createdAt: iso, version: 1, mergedFrom, ...(sub ? { subscription: sub, subSeq: 1 } : {}),
      },
      ConditionExpression: "attribute_not_exists(userId)",
    } });
  }
  items.push(
    { Put: { TableName: config.ledgerTable, Item: { userId: anonId, at: `${iso}#merge#${tail}`, type: "merge_out",
      giftTenths: -gift, paidTenths: -paid, ref: appleId } } },
    { Put: { TableName: config.ledgerTable, Item: { userId: appleId, at: `${iso}#merge#${tail}`, type: "merge_in",
      giftTenths: gift, paidTenths: paid, ref: anonId } } },
    { Update: { TableName: config.dailyTable, Key: { userId: appleId, day },
      UpdateExpression: "ADD addedTenths :a", ExpressionAttributeValues: { ":a": gift + paid } } },
  );
  return items;
}

/** Step 2: re-points what the device account owned. Every write is conditional or an overwrite. */
async function repoint(anonId, appleId, { ddb, store, subs, purchases, config }) {
  const anon = await store.read(anonId);
  const relinked = new Set();
  const relink = async (otid) => {
    if (!otid || relinked.has(otid)) return;
    relinked.add(otid);
    await subs.relink(otid, anonId, appleId);
  };
  await relink(anon?.subscription?.originalTransactionId);
  await purchases.moveAll(anonId, appleId, async (row) => {
    if (row.type === "subscription") return relink(row.originalTransactionId);
    if (row.status !== "credited" || !row.transactionId) return;
    try {
      await ddb.send(new UpdateCommand({
        TableName: config.promoTable, Key: { code: `iap#${row.transactionId}`, sk: "#purchase" },
        UpdateExpression: "SET userId = :to", ConditionExpression: "userId = :from",
        ExpressionAttributeValues: { ":to": appleId, ":from": anonId },
      }));
    } catch (e) {
      if (e?.name !== "ConditionalCheckFailedException") throw e; // moved already
    }
  });
  // The closed account's usage history has nothing left to explain.
  let start;
  do {
    const r = await ddb.send(new QueryCommand({
      TableName: config.dailyTable, KeyConditionExpression: "userId = :u", ExpressionAttributeValues: { ":u": anonId },
      ProjectionExpression: "userId, #d", ExpressionAttributeNames: { "#d": "day" }, ExclusiveStartKey: start,
    }));
    for (const row of r.Items ?? []) await ddb.send(new DeleteCommand({ TableName: config.dailyTable, Key: { userId: anonId, day: row.day } }));
    start = r.LastEvaluatedKey;
  } while (start);
}
