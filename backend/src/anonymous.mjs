// Anonymous device accounts (1.1 (4), App Review guideline 5.1.1(v): features that aren't account
// based must work without registering). On first launch the app calls POST /auth/anonymous and gets
// an ordinary account ("anon:<uuid>", the normal 300 signup credits) plus a device secret it keeps in
// the Keychain (this device only, survives reinstalling). The secret renews the 30-day session
// whenever it lapses, so a device account is never lost to an expired token. Sign in with Apple is
// optional and moves the device account into the Apple account (merge.mjs).
//
//   POST /auth/anonymous {}                          → new account (rate-limited per IP)
//   POST /auth/anonymous { deviceId, deviceSecret }  → a fresh session for that account, or, when it
//        was moved into an Apple account or deleted, a new device account WITHOUT the signup bonus
//   → { token, expiresAt, userId, created, signupCredits, deviceId?, deviceSecret? (new accounts only) }
//
// Repeated free credits are only held back by the app keeping its device secret (Keychain) and by
// the per-IP limit. TODO(DeviceCheck): verify a DeviceCheck token before the signup bonus — see
// `signupBonusAllowed` below, the one place that decides it.

import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { UpdateCommand } from "@aws-sdk/lib-dynamodb";

export const ANONYMOUS_PREFIX = "anon:";
export const isAnonymous = (userId) => typeof userId === "string" && userId.startsWith(ANONYMOUS_PREFIX);

export class DeviceAuthError extends Error {}
export class RateLimited extends Error {}

/** What the accounts table keeps of a device secret (the secret itself is never stored). */
export function secretHash(secret) {
  return createHash("sha256").update(`foreignmenu-device:${secret}`).digest("hex");
}

function sameHash(a, b) {
  const x = Buffer.from(String(a ?? ""), "hex"), y = Buffer.from(String(b ?? ""), "hex");
  return x.length === 32 && x.length === y.length && timingSafeEqual(x, y);
}

/**
 * The caller's IP. Behind CloudFront the Function URL sees CloudFront's address, and CloudFront
 * appends the viewer's to X-Forwarded-For, so the last entry is the one CloudFront vouches for.
 * (Calls straight to the Function URL can forge that header; the limit is a speed bump, not a wall.)
 */
export function clientIp(event) {
  const h = event.headers ?? {};
  const viewer = h["cloudfront-viewer-address"];
  if (viewer) return viewer.replace(/:\d+$/, "");
  const forwarded = String(h["x-forwarded-for"] ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  return forwarded.at(-1) ?? event.requestContext?.http?.sourceIp ?? "unknown";
}

/**
 * Whether a brand-new device account gets the signup bonus. Today: always (the Keychain and the IP
 * limit are the only guards). TODO(DeviceCheck): have the app send a DeviceCheck token, query the
 * device's two bits with Apple's DeviceCheck API (needs a DeviceCheck key in Secrets Manager), grant
 * only if bit 0 is unset, then set it.
 */
export async function signupBonusAllowed(/* { event, body } */) {
  return true;
}

export class AnonymousAccounts {
  /** `store` is the CreditStore; limits are new accounts per IP per hour / day. */
  constructor(ddb, store, { promoTable, signupBonus, anonPerIpHour, anonPerIpDay }) {
    Object.assign(this, { ddb, store, promoTable, signupBonus, anonPerIpHour, anonPerIpDay });
  }

  /**
   * Counts one new account against `ip` in this hour's and this day's window, or throws RateLimited.
   * Counters are items in the promo table with a TTL attribute (expiresEpoch), so they clean up.
   */
  async takeSlot(ip, now = new Date()) {
    const key = `rate#anon#${createHash("sha256").update(`foreignmenu-ip:${ip}`).digest("hex").slice(0, 32)}`;
    const iso = now.toISOString();
    const windows = [
      { sk: `h#${iso.slice(0, 13)}`, limit: this.anonPerIpHour, ttl: 2 * 3600 },
      { sk: `d#${iso.slice(0, 10)}`, limit: this.anonPerIpDay, ttl: 2 * 86400 },
    ];
    for (const w of windows) {
      if (!(w.limit > 0)) continue;
      try {
        await this.ddb.send(new UpdateCommand({
          TableName: this.promoTable, Key: { code: key, sk: w.sk },
          UpdateExpression: "ADD #h :one SET expiresEpoch = :ttl",
          ConditionExpression: "attribute_not_exists(#h) OR #h < :limit",
          ExpressionAttributeNames: { "#h": "hits" },
          ExpressionAttributeValues: { ":one": 1, ":limit": w.limit, ":ttl": Math.floor(now.getTime() / 1000) + w.ttl },
        }));
      } catch (e) {
        if (e?.name === "ConditionalCheckFailedException") throw new RateLimited("too many new accounts from this network");
        throw e;
      }
    }
  }

  /**
   * POST /auth/anonymous. Returns { userId, created, signupCredits, deviceSecret? }; the caller
   * issues the session. Throws DeviceAuthError for a wrong secret, RateLimited.
   */
  async open({ deviceId, deviceSecret } = {}, { ip, bonusAllowed = true, now = new Date() } = {}) {
    let predecessor = null;
    if (typeof deviceId === "string" && deviceId && typeof deviceSecret === "string" && deviceSecret) {
      if (!isAnonymous(deviceId) || deviceId.length > 80) throw new DeviceAuthError("not a device account");
      const item = await this.store.read(deviceId);
      if (item) {
        if (!sameHash(item.deviceSecretHash, secretHash(deviceSecret))) throw new DeviceAuthError("wrong device secret");
        if (!item.mergedInto) return { userId: deviceId, created: false, signupCredits: 0 };
        predecessor = deviceId; // moved into an Apple account: this device starts again, empty
      } else if (await this.store.wasDeleted(deviceId)) {
        predecessor = deviceId; // deleted: no second signup bonus for the same device
      }
      // Unknown and never deleted: treated as a first launch (anyone can omit the id anyway).
    }
    await this.takeSlot(ip, now);
    const bonus = predecessor || !bonusAllowed ? 0 : this.signupBonus;
    const secret = randomBytes(32).toString("base64url");
    const userId = `${ANONYMOUS_PREFIX}${randomUUID()}`;
    await this.store.openAccount(userId, {
      bonus, fields: { kind: "anonymous", deviceSecretHash: secretHash(secret), ...(predecessor ? { predecessor } : {}) },
    }, now);
    return { userId, created: true, signupCredits: bonus, deviceSecret: secret, predecessor };
  }
}
