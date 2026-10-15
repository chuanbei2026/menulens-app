// In-app purchases of credits (StoreKit 2 consumables). The app sends the transaction's JWS
// (`jwsRepresentation`); we verify it ourselves — no App Store Server API key needed:
//   1. the x5c chain in the JWS header ends at Apple Root CA - G3 (pinned by fingerprint), each
//      certificate is signed by the next and is currently valid, and the leaf is Apple's
//      receipt-signing certificate (OID 1.2.840.113635.100.6.11.1);
//   2. the ES256 signature over header.payload verifies with the leaf's key;
//   3. the payload is ours (bundle id, a known product, our account token, not revoked).
// Crediting is idempotent per transactionId (see CreditStore.creditPurchase).

import { createHash, verify, X509Certificate } from "node:crypto";

/** SHA-256 of Apple Root CA - G3 (https://www.apple.com/certificateauthority/AppleRootCA-G3.cer). */
export const APPLE_ROOT_G3_SHA256 =
  "63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79";

const RECEIPT_SIGNING_OID = "1.2.840.113635.100.6.11.1";

/** What each product adds. No bonus (unlike DateSeries): the 300 free credits are generous enough.
 * Prices live in App Store Connect: US$0.99 / 4.99 / 19.99. */
export const PRODUCTS = {
  "ai.xiangyang.MenuLens.credits.100": { credits: 100, bonus: 0 },
  "ai.xiangyang.MenuLens.credits.500": { credits: 500, bonus: 0 },
  "ai.xiangyang.MenuLens.credits.2000": { credits: 2000, bonus: 0 },
};

export class PurchaseError extends Error {
  constructor(reason, message = reason) {
    super(message);
    this.reason = reason;
  }
}

/**
 * The appAccountToken the app attaches to purchases: a UUID derived from the user id, so a
 * transaction can only be credited to the account that made it.
 */
export function accountToken(userId) {
  const h = createHash("sha256").update(`foreignmenu-iap:${userId}`).digest("hex");
  // Shape it as a version-4-style UUID (StoreKit only needs a valid UUID).
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

function b64urlJSON(part) {
  return JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
}

/**
 * Verifies a StoreKit 2 JWS and returns its payload. `rootFingerprint` and `now` are injectable
 * for tests (which sign with their own throwaway CA).
 */
export function verifyAppleJWS(jws, { rootFingerprint = APPLE_ROOT_G3_SHA256, now = new Date() } = {}) {
  if (typeof jws !== "string" || jws.length > 20000) throw new PurchaseError("bad_jws");
  const parts = jws.split(".");
  if (parts.length !== 3) throw new PurchaseError("bad_jws");
  let header, payload;
  try {
    header = b64urlJSON(parts[0]);
    payload = b64urlJSON(parts[1]);
  } catch {
    throw new PurchaseError("bad_jws");
  }
  if (header.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length < 2) throw new PurchaseError("bad_jws");

  let chain;
  try {
    chain = header.x5c.map((der) => new X509Certificate(Buffer.from(der, "base64")));
  } catch {
    throw new PurchaseError("bad_certificate");
  }
  const root = chain[chain.length - 1];
  if (root.fingerprint256 !== rootFingerprint) throw new PurchaseError("untrusted_root");
  for (let i = 0; i < chain.length; i++) {
    const cert = chain[i];
    const issuer = chain[Math.min(i + 1, chain.length - 1)];
    if (!cert.verify(issuer.publicKey)) throw new PurchaseError("bad_certificate");
    if (now < new Date(cert.validFrom) || now > new Date(cert.validTo)) throw new PurchaseError("expired_certificate");
  }
  // The leaf must be Apple's receipt-signing certificate (marker extension present in its DER).
  if (!chain[0].raw.includes(oidBytes(RECEIPT_SIGNING_OID))) throw new PurchaseError("bad_certificate");

  const ok = verify("sha256", Buffer.from(`${parts[0]}.${parts[1]}`), { key: chain[0].publicKey, dsaEncoding: "ieee-p1363" },
    Buffer.from(parts[2], "base64url"));
  if (!ok) throw new PurchaseError("bad_signature");
  return payload;
}

/** DER encoding of an OID's value bytes (with tag and length), to find an extension in a cert. */
export function oidBytes(oid) {
  const [a, b, ...rest] = oid.split(".").map(Number);
  const body = [40 * a + b];
  for (const n of rest) {
    const bytes = [n & 0x7f];
    for (let v = n >>> 7; v > 0; v >>>= 7) bytes.unshift((v & 0x7f) | 0x80);
    body.push(...bytes);
  }
  return Buffer.from([0x06, body.length, ...body]);
}

/**
 * Checks a verified transaction payload against our app and the signed-in user and returns what
 * to credit. `allowSandbox` admits TestFlight / sandbox purchases (they cost the tester nothing).
 */
export function creditableTransaction(payload, { userId, bundleId, allowSandbox }) {
  if (payload.bundleId !== bundleId) throw new PurchaseError("wrong_app");
  const product = PRODUCTS[payload.productId];
  if (!product) throw new PurchaseError("unknown_product");
  if (payload.type && payload.type !== "Consumable") throw new PurchaseError("unknown_product");
  if (payload.revocationDate) throw new PurchaseError("revoked");
  const env = payload.environment;
  if (env !== "Production" && !(allowSandbox && env === "Sandbox")) throw new PurchaseError("wrong_environment");
  if (payload.appAccountToken && payload.appAccountToken.toLowerCase() !== accountToken(userId)) {
    throw new PurchaseError("wrong_account");
  }
  const quantity = Math.max(1, Math.min(10, Number(payload.quantity) || 1));
  if (typeof payload.transactionId !== "string" || !payload.transactionId) throw new PurchaseError("bad_jws");
  return {
    transactionId: payload.transactionId,
    productId: payload.productId,
    environment: env,
    credits: (product.credits + product.bonus) * quantity,
  };
}
