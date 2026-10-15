// Authentication without third-party packages:
// - verify Sign in with Apple identity tokens (RS256, Apple's public JWKS)
// - issue / verify our own session tokens (HS256, key in Secrets Manager)
import { createHmac, createPublicKey, timingSafeEqual, verify as verifySignature } from "node:crypto";

const APPLE_ISSUER = "https://appleid.apple.com";
const APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys";
const SESSION_ISSUER = "foreignmenu";

export class AuthError extends Error {}

const b64url = (buf) => Buffer.from(buf).toString("base64url");
const decodeJSON = (part) => JSON.parse(Buffer.from(part, "base64url").toString("utf8"));

function splitJWT(token) {
  const parts = String(token ?? "").split(".");
  if (parts.length !== 3) throw new AuthError("malformed token");
  try {
    return { header: decodeJSON(parts[0]), payload: decodeJSON(parts[1]), signingInput: `${parts[0]}.${parts[1]}`, signature: Buffer.from(parts[2], "base64url") };
  } catch {
    throw new AuthError("malformed token"); // garbage that merely has two dots
  }
}

function checkTimes(payload, nowSec) {
  if (typeof payload.exp !== "number" || payload.exp <= nowSec) throw new AuthError("token expired");
  if (typeof payload.iat === "number" && payload.iat > nowSec + 300) throw new AuthError("token issued in the future");
}

// --- Apple --------------------------------------------------------------------------------

let appleKeysCache = { keys: [], fetchedAt: 0 };

async function appleKeys(forceRefresh = false) {
  const stale = Date.now() - appleKeysCache.fetchedAt > 6 * 3600 * 1000;
  if (forceRefresh || stale || appleKeysCache.keys.length === 0) {
    const res = await fetch(APPLE_KEYS_URL);
    if (!res.ok) throw new Error(`Apple JWKS fetch failed: ${res.status}`);
    appleKeysCache = { keys: (await res.json()).keys, fetchedAt: Date.now() };
  }
  return appleKeysCache.keys;
}

/**
 * Verifies a Sign in with Apple identity token and returns its claims.
 * `keys` can be injected for tests; otherwise Apple's JWKS is fetched and cached.
 */
export async function verifyAppleIdentityToken(token, { audience, keys, nowSec = Math.floor(Date.now() / 1000) }) {
  const { header, payload, signingInput, signature } = splitJWT(token);
  if (header.alg !== "RS256") throw new AuthError("unexpected alg");
  let jwk = (keys ?? await appleKeys()).find((k) => k.kid === header.kid);
  if (!jwk && !keys) jwk = (await appleKeys(true)).find((k) => k.kid === header.kid); // Apple rotated keys
  if (!jwk) throw new AuthError("unknown signing key");
  const ok = verifySignature("RSA-SHA256", Buffer.from(signingInput), createPublicKey({ key: jwk, format: "jwk" }), signature);
  if (!ok) throw new AuthError("bad signature");
  if (payload.iss !== APPLE_ISSUER) throw new AuthError("wrong issuer");
  if (!audience.includes(payload.aud)) throw new AuthError("wrong audience");
  checkTimes(payload, nowSec);
  if (!payload.sub) throw new AuthError("missing subject");
  return payload;
}

// --- Our session tokens -------------------------------------------------------------------

export function issueSessionToken(userId, secret, { days, nowSec = Math.floor(Date.now() / 1000) }) {
  const header = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const exp = nowSec + days * 86400;
  const payload = b64url(JSON.stringify({ iss: SESSION_ISSUER, sub: userId, iat: nowSec, exp }));
  const sig = b64url(createHmac("sha256", secret).update(`${header}.${payload}`).digest());
  return { token: `${header}.${payload}.${sig}`, expiresAt: new Date(exp * 1000).toISOString() };
}

/** Returns the user id of a valid session token, or throws AuthError. */
export function verifySessionToken(token, secret, { nowSec = Math.floor(Date.now() / 1000) } = {}) {
  const { header, payload, signingInput, signature } = splitJWT(token);
  if (header.alg !== "HS256") throw new AuthError("unexpected alg");
  const expected = createHmac("sha256", secret).update(signingInput).digest();
  if (expected.length !== signature.length || !timingSafeEqual(expected, signature)) throw new AuthError("bad signature");
  if (payload.iss !== SESSION_ISSUER) throw new AuthError("wrong issuer");
  checkTimes(payload, nowSec);
  return payload.sub;
}
