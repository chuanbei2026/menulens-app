import assert from "node:assert/strict";
import { test } from "node:test";
import { generateKeyPairSync, verify } from "node:crypto";
import { clientSecret, exchangeCode, revokeToken } from "../src/appleRevoke.mjs";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const key = { teamId: "LNP5ER743F", keyId: "ABC123DEFG", privateKey: privateKey.export({ type: "pkcs8", format: "pem" }) };

test("the client secret is an ES256 JWT Apple can verify", () => {
  const jwt = clientSecret(key, "ai.xiangyang.MenuLens", 1_800_000_000);
  const [h, p, s] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h, "base64url")), { alg: "ES256", kid: "ABC123DEFG" });
  assert.deepEqual(JSON.parse(Buffer.from(p, "base64url")),
    { iss: "LNP5ER743F", iat: 1_800_000_000, exp: 1_800_000_300, aud: "https://appleid.apple.com", sub: "ai.xiangyang.MenuLens" });
  assert.ok(verify("sha256", Buffer.from(`${h}.${p}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(s, "base64url")));
});

test("code exchange and revocation post the right forms", async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, form: Object.fromEntries(new URLSearchParams(init.body)) });
    return new Response(url.endsWith("/token") ? JSON.stringify({ refresh_token: "r-1" }) : "", { status: 200 });
  };
  assert.equal(await exchangeCode("c-1", key, "ai.xiangyang.MenuLens", fetchImpl), "r-1");
  await revokeToken("r-1", key, "ai.xiangyang.MenuLens", fetchImpl);
  assert.equal(calls[0].url, "https://appleid.apple.com/auth/token");
  assert.equal(calls[0].form.grant_type, "authorization_code");
  assert.equal(calls[0].form.code, "c-1");
  assert.equal(calls[1].url, "https://appleid.apple.com/auth/revoke");
  assert.deepEqual([calls[1].form.token, calls[1].form.token_type_hint, calls[1].form.client_id], ["r-1", "refresh_token", "ai.xiangyang.MenuLens"]);
});

test("an Apple error surfaces as an exception (the caller logs it and carries on)", async () => {
  const fetchImpl = async () => new Response('{"error":"invalid_grant"}', { status: 400 });
  await assert.rejects(exchangeCode("bad", key, "ai.xiangyang.MenuLens", fetchImpl), /invalid_grant/);
});
