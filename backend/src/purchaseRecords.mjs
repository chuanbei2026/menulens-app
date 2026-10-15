// Every purchase attempt, one item per transaction, per user: what was bought, what it cost, where,
// and what we did with it (credited / duplicate / rejected). For support, refunds and revenue; the
// ledger only has the credit movement, and the iap# markers only guard against double crediting.
//
// purchases (PK userId, SK sk = "<ISO time>#<transactionId>"):
//   transactionId, originalTransactionId, productId, quantity, credits, bonus,
//   price (decimal, the customer's currency), currency, storefront (alpha-3), environment,
//   purchaseDate, status ("credited" | "duplicate" | "rejected"), reason (rejected only), at
// Kept when the account is deleted: they are financial records (like the ledger).

import { PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { logEvent } from "./log.mjs";

/** The facts worth keeping from a verified StoreKit 2 transaction payload (null-safe). */
export function transactionFacts(payload) {
  if (!payload || typeof payload !== "object") return {};
  const price = typeof payload.price === "number" ? payload.price / 1000 : undefined; // StoreKit: milli-units
  const iso = (ms) => (typeof ms === "number" ? new Date(ms).toISOString() : undefined);
  const facts = {
    transactionId: payload.transactionId, originalTransactionId: payload.originalTransactionId,
    productId: payload.productId, quantity: payload.quantity, price, currency: payload.currency,
    storefront: payload.storefront, environment: payload.environment, purchaseDate: iso(payload.purchaseDate),
  };
  return Object.fromEntries(Object.entries(facts).filter(([, v]) => v !== undefined && v !== null && v !== ""));
}

export class PurchaseRecords {
  constructor(ddb, table) {
    Object.assign(this, { ddb, table });
  }

  /** Best effort: a failure is logged and never fails the purchase itself. */
  async record(userId, fields, now = new Date()) {
    if (!this.table) return;
    const at = now.toISOString();
    const item = { userId, sk: `${at}#${fields.transactionId ?? "unknown"}`, at, ...fields };
    try {
      await this.ddb.send(new PutCommand({ TableName: this.table, Item: item }));
    } catch (e) {
      logEvent("ERROR", "purchase record failed", { userId, transactionId: fields.transactionId, error: String(e?.message ?? e) });
    }
  }

  /** A user's purchases, newest first. */
  async list(userId, limit = 100) {
    const r = await this.ddb.send(new QueryCommand({
      TableName: this.table, KeyConditionExpression: "userId = :u", ExpressionAttributeValues: { ":u": userId },
      ScanIndexForward: false, Limit: limit,
    }));
    return r.Items ?? [];
  }
}
