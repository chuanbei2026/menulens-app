// The Lambda handler end to end with nothing on the network: the AWS SDK clients answer from the
// in-memory DynamoDB and a fixed session key, OpenAI from a stubbed fetch. Routes, auth, the /menu
// prefix, covered vs. charged calls, and that notifications always get a 200.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createPrivateKey, generateKeyPairSync, sign, X509Certificate } from "node:crypto";
import { before, test } from "node:test";
import { DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb";
import { SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import { issueSessionToken } from "../src/auth.mjs";
import { accountToken } from "../src/purchase.mjs";
import { FakeDDB } from "./fakeddb.mjs";

const SESSION_KEY = "handler-test-session-key";
const fake = new FakeDDB();
let handler;
const openAICalls = [];

// Sign in with Apple: identity tokens signed with our own RSA key, served as Apple's JWKS.
const apple = generateKeyPairSync("rsa", { modulusLength: 2048 });
const appleJwk = { ...apple.publicKey.export({ format: "jwk" }), kid: "test-kid", alg: "RS256", use: "sig" };
function appleToken(sub) {
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const nowSec = Math.floor(Date.now() / 1000);
  const head = `${enc({ alg: "RS256", kid: "test-kid" })}.${enc({ iss: "https://appleid.apple.com", aud: "ai.xiangyang.MenuLens", sub, iat: nowSec, exp: nowSec + 600 })}`;
  return `${head}.${sign("RSA-SHA256", Buffer.from(head), apple.privateKey).toString("base64url")}`;
}

before(async () => {
  // Drop the handler's own JSON log lines; everything else (the test runner's reports) passes.
  const write = process.stdout.write.bind(process.stdout);
  process.stdout.write = (chunk, ...rest) => (String(chunk).startsWith('{"time"') ? true : write(chunk, ...rest));
  Object.assign(process.env, { SESSION_SECRET_ARN: "test-session", AWS_REGION: "us-west-2" });
  DynamoDBDocumentClient.prototype.send = (cmd) => fake.send(cmd);
  SecretsManagerClient.prototype.send = async () => ({ SecretString: SESSION_KEY });
  globalThis.fetch = async (url, init) => {
    if (url === "https://appleid.apple.com/auth/keys") return new Response(JSON.stringify({ keys: [appleJwk] }), { status: 200 });
    if (url !== "https://api.openai.com/v1/images/generations") throw new Error(`unexpected network call: ${url}`);
    openAICalls.push(JSON.parse(init.body));
    const usage = { input_tokens: 60, input_tokens_details: { text_tokens: 60, image_tokens: 0 }, output_tokens: 1056 };
    return new Response(JSON.stringify({ data: [{ b64_json: "AAAA" }], usage }), { status: 200 });
  };
  globalThis.awslambda = {
    streamifyResponse: (fn) => fn,
    HttpResponseStream: { from: (stream, meta) => Object.assign(stream, { meta }) },
  };
  ({ handler } = await import("../src/index.mjs"));
});

async function call(method, path, { userId, token, body, headers = {} } = {}) {
  const chunks = [];
  const stream = { write: (c) => chunks.push(String(c)), end: () => {} };
  const bearer = token ?? (userId ? issueSessionToken(userId, SESSION_KEY, { days: 1 }).token : null);
  const auth = bearer ? { authorization: `Bearer ${bearer}` } : {};
  await handler({
    rawPath: path, requestContext: { http: { method } }, headers: { ...auth, ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  }, stream, { awsRequestId: "test" });
  return { status: stream.meta?.statusCode, json: JSON.parse(chunks.join("") || "null") };
}

const account = (userId) => fake.get("foreignmenu-accounts", { userId });
const imageBody = { prompt: "a bowl of ramen" };

test("GET /credits reports no subscription for a plain account, with the fair-use size", async () => {
  await call("POST", "/menu/image", { userId: "apple:plain", body: imageBody, headers: { "x-storefront": "USA" } }); // opens it
  const r = await call("GET", "/menu/credits", { userId: "apple:plain" });
  assert.equal(r.status, 200);
  assert.equal(r.json.appAccountToken, accountToken("apple:plain"));
  assert.deepEqual(r.json.subscription, {
    active: false, productId: null, expiresAt: null, autoRenew: null, monthUsedCredits: 0, monthFairUseCredits: 600,
  });
});

test("a subscriber's dish picture is covered, a non-subscriber's charged", async () => {
  const plain = await call("POST", "/menu/image", { userId: "apple:plain", body: imageBody, headers: { "x-storefront": "USA" } });
  assert.equal(plain.status, 200);
  assert.ok(plain.json.credits.charged >= 0 && plain.json.credits.covered === 0);
  assert.ok(account("apple:plain").giftTenths < 3000);

  // A subscriber, as POST /subscription leaves the account.
  await call("GET", "/menu/credits", { userId: "apple:sub" });
  await call("POST", "/menu/image", { userId: "apple:sub", body: imageBody, headers: { "x-storefront": "USA" } }); // opens it, charged
  const a = account("apple:sub");
  fake.put("foreignmenu-accounts", { ...a, subscription: {
    productId: "ai.xiangyang.MenuLens.sub.monthly", originalTransactionId: "1", transactionId: "1", environment: "Production",
    expiresAt: new Date(Date.now() + 30 * 86400000).toISOString(),
  } }, ["userId"]);
  const giftBefore = a.giftTenths + 500; // +50 subscriber grant on this first use while subscribed
  const r = await call("POST", "/menu/image", { userId: "apple:sub", body: imageBody, headers: { "x-storefront": "USA" } });
  assert.equal(r.status, 200);
  assert.equal(r.json.credits.charged, 0);
  assert.equal(account("apple:sub").giftTenths, giftBefore);
  assert.ok(account("apple:sub").coveredTenths > 0);
  const credits = await call("GET", "/menu/credits", { userId: "apple:sub" });
  assert.equal(credits.json.subscription.active, true);
  assert.equal(credits.json.subscription.monthFairUseCredits, 600);
  const usage = await call("GET", "/usage", { userId: "apple:sub" });
  assert.equal(usage.json.subscription.active, true);
  assert.ok(openAICalls.length >= 3);
});

test("POST /subscription only trusts Apple's root (the test chain is refused) and keeps the attempt", async () => {
  const dir = new URL("./fixtures/iap/", import.meta.url);
  const pem = (f) => readFileSync(new URL(f, dir), "utf8");
  const x5c = ["leaf.pem", "int.pem", "root.pem"].map((f) => new X509Certificate(pem(f)).raw.toString("base64"));
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = `${enc({ alg: "ES256", x5c })}.${enc({ productId: "ai.xiangyang.MenuLens.sub.monthly", transactionId: "7" })}`;
  const jws = `${head}.${sign("sha256", Buffer.from(head), { key: createPrivateKey(pem("leaf.pk8")), dsaEncoding: "ieee-p1363" }).toString("base64url")}`;
  const r = await call("POST", "/menu/subscription", { userId: "apple:plain", body: { jws } });
  assert.equal(r.status, 400);
  assert.equal(r.json.reason, "untrusted_root");
  const records = [...fake.table("foreignmenu-purchases").values()].filter((x) => x.userId === "apple:plain");
  assert.deepEqual(records.map((x) => [x.type, x.status, x.reason]), [["subscription", "rejected", "untrusted_root"]]);
  assert.equal((await call("POST", "/subscription", { body: { jws } })).status, 401); // needs a session
});

test("App Store notifications need no session and always get a 200", async () => {
  for (const body of [{ signedPayload: "garbage" }, {}, "not json"]) {
    const r = await call("POST", "/menu/appstore/notifications", { body });
    assert.deepEqual([r.status, r.json], [200, { ok: true }]);
  }
  assert.equal((await call("POST", "/appstore/notifications", { body: {} })).status, 200);
});

// --- 1.1 (4): device accounts, linking Sign in with Apple, redeem codes retired --------------

const ip = (n) => ({ "x-forwarded-for": `198.51.100.${n}` });

test("POST /auth/anonymous: a device account with 300 credits, and every route works on it", async () => {
  const r = await call("POST", "/menu/auth/anonymous", { body: {}, headers: ip(1) });
  assert.equal(r.status, 200);
  assert.ok(r.json.userId.startsWith("anon:"));
  assert.equal(r.json.deviceId, r.json.userId);
  assert.ok(r.json.token && r.json.deviceSecret && r.json.expiresAt);
  assert.deepEqual([r.json.created, r.json.signupCredits], [true, 300]);
  const token = r.json.token;
  const credits = await call("GET", "/menu/credits", { token });
  assert.deepEqual([credits.status, credits.json.totalCredits], [200, 300]);
  assert.equal(credits.json.appAccountToken, accountToken(r.json.userId)); // purchases and subscriptions use the account id
  assert.equal((await call("GET", "/menu/usage", { token })).status, 200);
  const pic = await call("POST", "/menu/image", { token, body: imageBody, headers: { "x-storefront": "USA" } });
  assert.equal(pic.status, 200);
  assert.equal((await call("GET", "/menu/models", { headers: { "x-storefront": "USA" } })).status, 200); // no session needed
  // Renewing with the device secret: same account, no new credits, no new secret.
  const again = await call("POST", "/menu/auth/anonymous", { body: { deviceId: r.json.userId, deviceSecret: r.json.deviceSecret }, headers: ip(1) });
  assert.deepEqual([again.status, again.json.userId, again.json.created, again.json.deviceSecret], [200, r.json.userId, false, undefined]);
  const wrong = await call("POST", "/menu/auth/anonymous", { body: { deviceId: r.json.userId, deviceSecret: "nope" }, headers: ip(1) });
  assert.deepEqual([wrong.status, wrong.json.reason], [401, "device"]);
  const refreshed = await call("POST", "/menu/auth/refresh", { token });
  assert.deepEqual([refreshed.status, refreshed.json.userId], [200, r.json.userId]);
});

test("POST /auth/anonymous is rate-limited per IP (429)", async () => {
  let last;
  for (let i = 0; i < 11; i++) last = await call("POST", "/auth/anonymous", { body: {}, headers: ip(2) });
  assert.deepEqual([last.status, last.json.reason], [429, "rate_limited"]);
  assert.equal((await call("POST", "/auth/anonymous", { body: {}, headers: ip(3) })).status, 200);
});

test("linking a new Apple ID attaches the device account: same balance, no new 300, Apple session", async () => {
  const d = (await call("POST", "/auth/anonymous", { body: {}, headers: ip(4) })).json;
  const link = await call("POST", "/menu/auth/apple/link", { token: d.token, body: { identityToken: appleToken("new.1") } });
  assert.equal(link.status, 200);
  assert.deepEqual([link.json.userId, link.json.linked, link.json.movedCredits], ["apple:new.1", "attach", 300]);
  const credits = await call("GET", "/credits", { token: link.json.token });
  assert.equal(credits.json.totalCredits, 300);
  // The old device session is refused with "merged", so the app knows to sign in again.
  const stale = await call("GET", "/credits", { token: d.token });
  assert.deepEqual([stale.status, stale.json.reason], [401, "merged"]);
  // A retry (the app missed the answer) gives the same session, moves nothing.
  const retry = await call("POST", "/auth/apple/link", { token: d.token, body: { identityToken: appleToken("new.1") } });
  assert.deepEqual([retry.status, retry.json.userId, retry.json.linked, retry.json.movedCredits], [200, "apple:new.1", "already", 0]);
  assert.equal((await call("GET", "/credits", { userId: "apple:new.1" })).json.totalCredits, 300);
  // Signing out of Apple: the device secret now opens a fresh, empty device account.
  const next = await call("POST", "/auth/anonymous", { body: { deviceId: d.deviceId, deviceSecret: d.deviceSecret }, headers: ip(4) });
  assert.deepEqual([next.status, next.json.created, next.json.signupCredits], [200, true, 0]);
  assert.notEqual(next.json.userId, d.userId);
});

test("linking an Apple ID that has an account merges the device balance into it", async () => {
  const existing = await call("POST", "/auth/apple", { body: { identityToken: appleToken("old.2") } });
  assert.deepEqual([existing.status, existing.json.userId], [200, "apple:old.2"]);
  const d = (await call("POST", "/auth/anonymous", { body: {}, headers: ip(5) })).json;
  const link = await call("POST", "/auth/apple/link", { token: d.token, body: { identityToken: appleToken("old.2") } });
  assert.deepEqual([link.status, link.json.linked, link.json.movedCredits], [200, "merge", 300]);
  assert.equal((await call("GET", "/credits", { token: link.json.token })).json.totalCredits, 600);
  assert.deepEqual(account("apple:old.2").mergedFrom, [d.userId]);
  assert.equal(account(d.userId).mergedInto, "apple:old.2");
  // The same device account can't then go into a second Apple account.
  const other = await call("POST", "/auth/apple/link", { token: d.token, body: { identityToken: appleToken("third.3") } });
  assert.deepEqual([other.status, other.json.reason], [409, "conflict"]);
  // From an Apple session, link is a plain sign-in (switching accounts moves nothing).
  const sw = await call("POST", "/auth/apple/link", { userId: "apple:old.2", body: { identityToken: appleToken("third.3") } });
  assert.deepEqual([sw.status, sw.json.userId, sw.json.linked], [200, "apple:third.3", "switch"]);
  assert.equal((await call("POST", "/auth/apple/link", { body: { identityToken: appleToken("x") } })).status, 401); // needs a session
});

test("DELETE /account works for a device account (no Apple token to revoke); the device starts again empty", async () => {
  const d = (await call("POST", "/auth/anonymous", { body: {}, headers: ip(6) })).json;
  const del = await call("DELETE", "/menu/account", { token: d.token });
  assert.deepEqual([del.status, del.json], [200, { deleted: true }]);
  assert.equal(account(d.userId), undefined);
  assert.equal((await call("POST", "/auth/refresh", { token: d.token })).status, 401);
  const next = await call("POST", "/auth/anonymous", { body: { deviceId: d.deviceId, deviceSecret: d.deviceSecret }, headers: ip(6) });
  assert.deepEqual([next.status, next.json.created, next.json.signupCredits], [200, true, 0]);
});

test("POST /promo/redeem answers 410: redeem codes are retired", async () => {
  for (const r of [
    await call("POST", "/menu/promo/redeem", { userId: "apple:plain", body: { code: "LoveGulu" } }),
    await call("POST", "/promo/redeem", { body: { code: "LoveGulu" } }),
  ]) {
    assert.equal(r.status, 410);
    assert.equal(r.json.reason, "retired");
  }
});
