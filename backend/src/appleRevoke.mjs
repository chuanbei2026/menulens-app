// Sign in with Apple token revocation (App Store guideline 5.1.1(v): deleting an account must also
// revoke the user's Apple authorization). At sign-in the app sends the one-time authorizationCode; we
// exchange it for a refresh token (kept on the account item) and revoke that token when the account is
// deleted. Both calls are authenticated with a client secret: an ES256 JWT signed with the team's
// Sign in with Apple key (.p8), kept in Secrets Manager as {"teamId", "keyId", "privateKey"}.
// Without that secret everything here is skipped, and sign-in and deletion work as before.

import { sign } from "node:crypto";

const APPLE = "https://appleid.apple.com";
const b64url = (x) => Buffer.from(typeof x === "string" ? x : JSON.stringify(x)).toString("base64url");

/** The client_secret JWT Apple wants (valid 5 minutes; Apple allows up to 6 months). */
export function clientSecret({ teamId, keyId, privateKey }, clientId, nowSec = Math.floor(Date.now() / 1000)) {
  const header = b64url({ alg: "ES256", kid: keyId });
  const payload = b64url({ iss: teamId, iat: nowSec, exp: nowSec + 300, aud: APPLE, sub: clientId });
  const signature = sign("sha256", Buffer.from(`${header}.${payload}`), { key: privateKey, dsaEncoding: "ieee-p1363" });
  return `${header}.${payload}.${signature.toString("base64url")}`;
}

async function post(path, form, fetchImpl) {
  const r = await fetchImpl(`${APPLE}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(form).toString(),
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`apple ${path} ${r.status}: ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : {};
}

/** authorizationCode → refresh token (null if Apple didn't return one). */
export async function exchangeCode(code, key, clientId, fetchImpl = fetch) {
  const j = await post("/auth/token", { client_id: clientId, client_secret: clientSecret(key, clientId),
    code, grant_type: "authorization_code" }, fetchImpl);
  return j.refresh_token ?? null;
}

/** Revokes a refresh token. */
export async function revokeToken(token, key, clientId, fetchImpl = fetch) {
  await post("/auth/revoke", { client_id: clientId, client_secret: clientSecret(key, clientId),
    token, token_type_hint: "refresh_token" }, fetchImpl);
}
