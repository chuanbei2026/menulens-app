import assert from "node:assert/strict";
import { createSign, generateKeyPairSync } from "node:crypto";
import { test } from "node:test";
import { AuthError, issueSessionToken, verifyAppleIdentityToken, verifySessionToken } from "../src/auth.mjs";

const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: "jwk" }), kid: "test-kid", alg: "RS256", use: "sig" };
const now = 1_790_000_000;
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");

function appleToken(overrides = {}, kid = "test-kid") {
  const head = b64({ alg: "RS256", kid });
  const body = b64({ iss: "https://appleid.apple.com", aud: "ai.xiangyang.MenuLens", sub: "001234.abcd", iat: now - 10, exp: now + 600, ...overrides });
  const sig = createSign("RSA-SHA256").update(`${head}.${body}`).sign(privateKey).toString("base64url");
  return `${head}.${body}.${sig}`;
}
const opts = { audience: ["ai.xiangyang.MenuLens"], keys: [jwk], nowSec: now };

test("accepts a valid Apple identity token", async () => {
  const claims = await verifyAppleIdentityToken(appleToken(), opts);
  assert.equal(claims.sub, "001234.abcd");
});

test("rejects wrong audience, issuer, expiry, key and tampering", async () => {
  await assert.rejects(verifyAppleIdentityToken(appleToken({ aud: "com.evil.app" }), opts), AuthError);
  await assert.rejects(verifyAppleIdentityToken(appleToken({ iss: "https://evil.example" }), opts), AuthError);
  await assert.rejects(verifyAppleIdentityToken(appleToken({ exp: now - 1 }), opts), AuthError);
  await assert.rejects(verifyAppleIdentityToken(appleToken({}, "other-kid"), opts), AuthError);
  const [h, , s] = appleToken().split(".");
  const forged = `${h}.${b64({ iss: "https://appleid.apple.com", aud: "ai.xiangyang.MenuLens", sub: "someone-else", exp: now + 600 })}.${s}`;
  await assert.rejects(verifyAppleIdentityToken(forged, opts), AuthError);
  await assert.rejects(verifyAppleIdentityToken("not-a-jwt", opts), AuthError);
});

test("session tokens round-trip and reject tampering, wrong key and expiry", () => {
  const { token } = issueSessionToken("apple:001234.abcd", "secret-1", { days: 30, nowSec: now });
  assert.equal(verifySessionToken(token, "secret-1", { nowSec: now + 86400 }), "apple:001234.abcd");
  assert.throws(() => verifySessionToken(token, "secret-2", { nowSec: now }), AuthError);
  assert.throws(() => verifySessionToken("nope.nope.nope", "secret-1", { nowSec: now }), AuthError);
  assert.throws(() => verifySessionToken(token, "secret-1", { nowSec: now + 31 * 86400 }), AuthError);
  const [h, , s] = token.split(".");
  assert.throws(() => verifySessionToken(`${h}.${b64({ iss: "foreignmenu", sub: "apple:other", exp: now + 999 })}.${s}`, "secret-1", { nowSec: now }), AuthError);
});
