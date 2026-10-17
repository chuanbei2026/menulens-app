// The Lambda handler end to end with nothing on the network: the AWS SDK clients answer from the
// in-memory DynamoDB and a fixed session key, OpenAI from a stubbed fetch. Routes, auth, the /menu
// prefix, covered vs. charged calls, and that notifications always get a 200.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createPrivateKey, sign, X509Certificate } from "node:crypto";
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

before(async () => {
  // Drop the handler's own JSON log lines; everything else (the test runner's reports) passes.
  const write = process.stdout.write.bind(process.stdout);
  process.stdout.write = (chunk, ...rest) => (String(chunk).startsWith('{"time"') ? true : write(chunk, ...rest));
  Object.assign(process.env, { SESSION_SECRET_ARN: "test-session", AWS_REGION: "us-west-2" });
  DynamoDBDocumentClient.prototype.send = (cmd) => fake.send(cmd);
  SecretsManagerClient.prototype.send = async () => ({ SecretString: SESSION_KEY });
  globalThis.fetch = async (url, init) => {
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

async function call(method, path, { userId, body, headers = {} } = {}) {
  const chunks = [];
  const stream = { write: (c) => chunks.push(String(c)), end: () => {} };
  const auth = userId ? { authorization: `Bearer ${issueSessionToken(userId, SESSION_KEY, { days: 1 }).token}` } : {};
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
