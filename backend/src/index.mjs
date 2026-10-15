// ForeignMenu backend: one Lambda behind a Function URL in RESPONSE_STREAM mode. The app signs in
// with Apple and spends credits; the OpenAI key never leaves the server.
//
//   POST /auth/apple   { identityToken }        → { token, expiresAt, userId }
//   GET  /credits      (Bearer session token)   → { totalCredits, giftCredits, paidCredits, monthlyGrant, lastGrantPeriod, appAccountToken }
//   GET  /usage        (Bearer)                 → { balance, days: [{ date, spent, added, calls, balance }] } (last 30 days)
//   POST /purchase     { jws } (Bearer)         → credits a StoreKit 2 purchase
//   POST /promo/redeem { code } (Bearer)        → { code, credits, totalCredits, … }
//   DELETE /account    (Bearer)                 → { deleted: true }
//   POST /menu         (Bearer) Chat Completions body (messages, response_format, model?, temperature?,
//                      reasoning_effort?) → the OpenAI SSE stream, unchanged
//   POST /image        (Bearer) { prompt }      → the OpenAI Images JSON ({ data: [{ b64_json }] })
//   GET  /models?storefront=HKG                 → { default, images, models: [{ id, name, provider }] }
//                      what this storefront may use (regions.mjs); no sign-in needed
//   The app sends its App Store storefront (StoreKit, alpha-3) as `X-Storefront` on /menu and /image:
//   a model the storefront may not use answers 403 { reason: "region", models }.
//
// Credits are charged to 0.1 internally; every amount the API returns is a whole number (balances
// floored). Out of credits: 402 { error, reason: "credits", totalCredits, needed }.
import { randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb";
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import { config } from "./config.mjs";
import { AuthError, issueSessionToken, verifyAppleIdentityToken, verifySessionToken } from "./auth.mjs";
import { CreditStore, InsufficientCredits, PromoError, PurchaseConflict, balanceHistory, publicBalance, publicDay, toCredits } from "./credits.mjs";
import { accountToken, creditableTransaction, PurchaseError, verifyAppleJWS } from "./purchase.mjs";
import { instrument, newScope, requestScope, summarize } from "./ddbstats.mjs";
import { logEvent, logRequest } from "./log.mjs";
import { chatCostUsd, EXPECTED_IMAGE_OUTPUT_TOKENS, imageCostUsd, tenthsForUsd } from "./pricing.mjs";
import { catalogFor, normalizeStorefront, providerAllowed } from "./regions.mjs";
import { relayBedrockMenu } from "./bedrock.mjs";
import { exchangeCode, revokeToken } from "./appleRevoke.mjs";
import { generateImage, imageRequest, menuRequest, relayMenu, RequestError, upstreamMessage } from "./relay.mjs";

const ddb = instrument(DynamoDBDocumentClient.from(new DynamoDBClient({})));
const secrets = new SecretsManagerClient({});
const store = new CreditStore(ddb, config);

// Secrets are read once per container and reused while it stays warm.
const secretCache = new Map();
async function secretString(id) {
  if (!secretCache.has(id)) {
    const { SecretString } = await secrets.send(new GetSecretValueCommand({ SecretId: id }));
    secretCache.set(id, SecretString);
  }
  return secretCache.get(id);
}
/** {"key": …} or a bare value. */
async function secretKey(id) {
  const s = (await secretString(id)).trim();
  if (s.startsWith("{")) return JSON.parse(s).key;
  return s;
}

class HttpError extends Error {
  constructor(status, message, extra = {}) {
    super(message);
    Object.assign(this, { status, extra });
  }
}

function readBody(event) {
  if (!event.body) return {};
  const raw = event.isBase64Encoded ? Buffer.from(event.body, "base64").toString("utf8") : event.body;
  try { return JSON.parse(raw); } catch { throw new HttpError(400, "body must be JSON"); }
}

async function authenticate(event) {
  const header = event.headers?.authorization ?? event.headers?.Authorization ?? "";
  const token = header.replace(/^Bearer\s+/i, "");
  if (!token) throw new HttpError(401, "missing bearer token");
  try {
    return verifySessionToken(token, await secretKey(config.sessionSecretArn));
  } catch (e) {
    if (e instanceof AuthError) throw new HttpError(401, e.message);
    throw e;
  }
}

// --- Accounts and credits ------------------------------------------------------------------

async function grant(userId, ctx) {
  const { kind, item } = await store.grantIfDue(userId);
  if (kind === "reopen") logEvent("INFO", "account reopened after deletion (no signup bonus)", { requestId: ctx.requestId, userId });
  else if (kind) {
    ctx.grant = kind;
    logEvent("INFO", kind === "signup" ? "account created" : "monthly grant", { requestId: ctx.requestId, userId, grant: kind });
  }
  return item;
}

/** The Sign in with Apple key for token revocation, or null while it isn't set up. */
let siwaCache = { at: 0, key: null };
async function siwaKey() {
  // Re-checked every 10 minutes, so adding the secret later needs no deploy and a missing one costs
  // no Secrets Manager call per sign-in.
  if (Date.now() - siwaCache.at < 600_000) return siwaCache.key;
  let key = null;
  try { key = JSON.parse(await secretString(config.siwaSecretId)); } catch { /* not set up yet */ }
  siwaCache = { at: Date.now(), key };
  return key;
}

async function signInWithApple(event, ctx) {
  const { identityToken, authorizationCode } = readBody(event);
  let claims;
  try {
    claims = await verifyAppleIdentityToken(identityToken, { audience: config.appleAudience });
  } catch (e) {
    if (e instanceof AuthError) throw new HttpError(401, `apple: ${e.message}`);
    throw e;
  }
  const userId = `apple:${claims.sub}`;
  ctx.userId = userId;
  await grant(userId, ctx); // signing in counts as using the service: opens the account / this month's grant
  // Keep a refresh token so deleting the account can revoke the Apple authorization. Best effort: a
  // failure here never blocks signing in.
  if (typeof authorizationCode === "string" && authorizationCode) {
    const key = await siwaKey();
    if (key) {
      try {
        const refresh = await exchangeCode(authorizationCode, key, config.appleAudience[0]);
        if (refresh) await store.setAppleRefreshToken(userId, refresh);
        ctx.appleToken = refresh ? "stored" : "none";
      } catch (e) {
        logEvent("WARN", "apple code exchange failed", { requestId: ctx.requestId, userId, error: String(e.message).slice(0, 200) });
      }
    }
  }
  const session = issueSessionToken(userId, await secretKey(config.sessionSecretArn), { days: config.sessionDays });
  return { ...session, userId };
}

async function deleteAccount(event, ctx) {
  const userId = await authenticate(event);
  ctx.userId = userId;
  // Revoke the Apple authorization first (guideline 5.1.1(v)); the account goes either way.
  const token = await store.appleRefreshToken(userId);
  const key = token ? await siwaKey() : null;
  if (token && key) {
    try {
      await revokeToken(token, key, config.appleAudience[0]);
      ctx.appleRevoked = true;
    } catch (e) {
      logEvent("WARN", "apple token revoke failed", { requestId: ctx.requestId, userId, error: String(e.message).slice(0, 200) });
    }
  }
  await store.deleteAccount(userId);
  logEvent("INFO", "account deleted", { requestId: ctx.requestId, userId });
  return { deleted: true };
}

function emptyBalance() {
  return { total: 0, gift: 0, paid: 0, monthlyGrant: config.monthlyGrant };
}

async function getCredits(event, ctx) {
  const userId = await authenticate(event); // viewing the balance is not "use": no grant here
  ctx.userId = userId;
  const b = await store.balance(userId) ?? emptyBalance();
  return { ...publicBalance(b), appAccountToken: accountToken(userId) };
}

async function getUsage(event, ctx) {
  const userId = await authenticate(event);
  ctx.userId = userId;
  const [b, rows] = await Promise.all([store.balance(userId), store.dailyRows(userId, config.usageDays)]);
  const balance = b ?? emptyBalance();
  const days = balanceHistory(rows, { balance: balance.total, days: config.usageDays, timeZone: config.billingTimeZone });
  return { balance: publicBalance(balance), days: days.map(publicDay) };
}

async function purchase(event, ctx) {
  const userId = await authenticate(event);
  ctx.userId = userId;
  const { jws } = readBody(event);
  try {
    const payload = verifyAppleJWS(jws);
    const tx = creditableTransaction(payload, { userId, bundleId: config.appBundleId, allowSandbox: config.allowSandboxPurchases });
    await grant(userId, ctx);
    const result = await store.creditPurchase(userId, tx);
    logEvent("INFO", "purchase", { requestId: ctx.requestId, userId, productId: tx.productId, environment: tx.environment,
      credits: tx.credits, credited: result.credited });
    return { ...result, productId: tx.productId, ...publicBalance(await store.balance(userId)) };
  } catch (e) {
    if (e instanceof PurchaseError) {
      logEvent("WARN", "purchase rejected", { requestId: ctx.requestId, userId, reason: e.reason });
      throw new HttpError(400, e.reason, { reason: e.reason });
    }
    if (e instanceof PurchaseConflict) throw new HttpError(409, "purchase belongs to another account", { reason: "conflict" });
    throw e;
  }
}

const PROMO_STATUS = { not_found: 404, inactive: 410, expired: 410, used_up: 410, already_redeemed: 409 };

async function redeemPromo(event, ctx) {
  const userId = await authenticate(event);
  ctx.userId = userId;
  const { code } = readBody(event);
  if (typeof code !== "string" || code.length > 64) throw new HttpError(400, "code must be a string");
  await grant(userId, ctx);
  try {
    const result = await store.redeemPromo(userId, code);
    ctx.promo = result.code;
    logEvent("INFO", "promo redeemed", { requestId: ctx.requestId, userId, promo: result.code, credits: result.credits });
    return { ...result, ...publicBalance(await store.balance(userId)) };
  } catch (e) {
    if (e instanceof PromoError) throw new HttpError(PROMO_STATUS[e.reason] ?? 400, e.reason, { reason: e.reason });
    throw e;
  }
}

/** Reserves `tenths` for a model call, or answers 402 with the balance. */
async function reserve(userId, tenths, ref, account, ctx) {
  try {
    const split = await store.reserve(userId, tenths, ref, account);
    Object.assign(ctx, { ref, creditsReserved: toCredits(tenths) });
    return split;
  } catch (e) {
    if (e instanceof InsufficientCredits) {
      throw new HttpError(402, "credits used up", {
        reason: "credits", totalCredits: Math.floor(toCredits(e.balance.total)),
        needed: Math.ceil(toCredits(tenths)), monthlyGrant: e.balance.monthlyGrant,
      });
    }
    throw e;
  }
}

/** OpenAI's status, except problems with our own key or account, which the app can't fix. */
function upstreamStatus(status) {
  return [401, 403, 404].includes(status) ? 502 : status;
}

// --- Model calls ---------------------------------------------------------------------------

function storefrontOf(event) {
  return normalizeStorefront(event.headers?.["x-storefront"] ?? event.queryStringParameters?.storefront);
}


async function menu(event, stream, ctx) {
  const userId = await authenticate(event);
  ctx.userId = userId;
  if ((event.body?.length ?? 0) > config.maxRequestBytes) throw new HttpError(413, "request too large");
  const storefront = storefrontOf(event);
  const catalog = catalogFor(storefront);
  if (!catalog.default) throw new HttpError(403, "not available in this region", { reason: "region", models: [] });
  let req;
  try {
    req = menuRequest(readBody(event), { maxOutputTokens: config.maxOutputTokens, maxImages: config.maxImagesPerRequest,
      defaultModel: catalog.default });
  } catch (e) {
    if (e instanceof RequestError) throw new HttpError(400, e.message);
    throw e;
  }
  Object.assign(ctx, { model: req.model.id, images: req.images, inputChars: req.textChars, storefront }); // sizes only
  if (!providerAllowed(req.model.provider, storefront)) {
    throw new HttpError(403, "model not available in this region", { reason: "region", models: catalog.models.map((m) => m.id) });
  }
  const account = await grant(userId, ctx);
  const ref = randomUUID();
  const worst = tenthsForUsd(chatCostUsd(req.model, { input: req.inputTokens, output: config.expectedOutputTokens }));
  const split = await reserve(userId, worst, ref, account, ctx);

  let out;
  const write = (data) => {
    ctx.ttfbMs ??= Date.now() - ctx.startedAt;
    try { out.write(data); } catch { ctx.clientGone = true; /* keep draining upstream so we can settle */ }
  };
  const onStart = (status) => {
    ctx.upstreamStatus = status;
    ctx.status = 200;
    out = awslambda.HttpResponseStream.from(stream, {
      statusCode: 200, headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
    });
  };
  let result;
  try {
    result = req.model.provider === "bedrock"
      ? await relayBedrockMenu({ modelId: req.model.upstream, body: req.body, maxOutputTokens: config.maxBedrockOutputTokens, write, onStart })
      : await relayMenu({ apiKey: await secretKey(config.openAISecretId), body: req.body, write, onStart });
  } catch (e) {
    await store.settle(userId, split, 0, ref);
    ctx.creditsCharged = 0;
    if (!ctx.status) throw e;
    ctx.error = `upstream stream failed: ${e?.message ?? e}`;
    write(`data: ${JSON.stringify({ error: { message: "upstream connection failed; credits refunded" } })}\n\n`);
    out.end();
    return;
  }
  if (!result.ok) {
    await store.settle(userId, split, 0, ref);
    Object.assign(ctx, { creditsCharged: 0, upstreamStatus: result.status });
    throw new HttpError(upstreamStatus(result.status), upstreamMessage(result.errorBody));
  }
  // Missing usage on success (shouldn't happen) → keep the reservation.
  const actual = result.usage ? tenthsForUsd(chatCostUsd(req.model, result.usage)) : split.fromGift + split.fromPaid;
  Object.assign(ctx, {
    creditsCharged: toCredits(actual), finishReason: result.finishReason ?? "unknown",
    inputTokens: result.usage?.input ?? 0, cachedTokens: result.usage?.cached ?? 0, outputTokens: result.usage?.output ?? 0,
    costUsd: result.usage ? Number(chatCostUsd(req.model, result.usage).toFixed(6)) : 0,
  });
  if (!result.usage) logEvent("WARN", "usage missing; kept full reservation", { requestId: ctx.requestId, userId, ref });
  try {
    await store.settle(userId, split, actual, ref);
    const b = await store.balance(userId);
    ctx.creditsLeft = toCredits(b.total);
    const { totalCredits, giftCredits, paidCredits } = publicBalance(b);
    // After OpenAI's [DONE]: clients that stop reading there simply never see it.
    write(`event: foreignmenu.credits\ndata: ${JSON.stringify({ charged: Math.round(toCredits(actual)), totalCredits, giftCredits, paidCredits })}\n\n`);
  } catch (e) {
    logEvent("ERROR", "settlement failed", { requestId: ctx.requestId, userId, ref, actualTenths: actual, error: String(e) });
  }
  out.end();
}

async function image(event, ctx) {
  const userId = await authenticate(event);
  ctx.userId = userId;
  let req;
  try {
    req = imageRequest(readBody(event), { maxPromptChars: config.maxPromptChars });
  } catch (e) {
    if (e instanceof RequestError) throw new HttpError(400, e.message);
    throw e;
  }
  const storefront = storefrontOf(event);
  ctx.storefront = storefront;
  if (!providerAllowed("openai", storefront)) throw new HttpError(403, "dish pictures are not available in this region", { reason: "region" });
  ctx.model = req.body.model;
  ctx.inputChars = req.body.prompt.length;
  const account = await grant(userId, ctx);
  const ref = randomUUID();
  const worst = tenthsForUsd(imageCostUsd({ text: req.promptTokens, output: EXPECTED_IMAGE_OUTPUT_TOKENS }));
  const split = await reserve(userId, worst, ref, account, ctx);
  let result;
  try {
    result = await generateImage({ apiKey: await secretKey(config.openAISecretId), body: req.body });
  } catch (e) {
    await store.settle(userId, split, 0, ref);
    ctx.creditsCharged = 0;
    throw e;
  }
  ctx.upstreamStatus = result.status;
  if (!result.ok) {
    await store.settle(userId, split, 0, ref);
    ctx.creditsCharged = 0;
    throw new HttpError(upstreamStatus(result.status), upstreamMessage(result.errorBody));
  }
  const actual = result.usage ? tenthsForUsd(imageCostUsd(result.usage)) : split.fromGift + split.fromPaid;
  Object.assign(ctx, {
    creditsCharged: toCredits(actual), inputTokens: (result.usage?.text ?? 0) + (result.usage?.image ?? 0),
    outputTokens: result.usage?.output ?? 0, costUsd: result.usage ? Number(imageCostUsd(result.usage).toFixed(6)) : 0,
  });
  await store.settle(userId, split, actual, ref);
  const b = await store.balance(userId);
  ctx.creditsLeft = toCredits(b.total);
  const { totalCredits } = publicBalance(b);
  return { ...result.json, credits: { charged: Math.round(toCredits(actual)), totalCredits } };
}

// --- Entry point ---------------------------------------------------------------------------

function sendJSON(stream, status, body, ctx) {
  ctx.status = status;
  const out = awslambda.HttpResponseStream.from(stream, { statusCode: status, headers: { "Content-Type": "application/json" } });
  out.write(JSON.stringify(body));
  out.end();
}

export const handler = awslambda.streamifyResponse((event, stream, context) =>
  requestScope.run(newScope(), () => handle(event, stream, context)));

async function handle(event, stream, context) {
  const method = event.requestContext?.http?.method ?? "GET";
  const path = event.rawPath ?? "/";
  const ctx = { requestId: context?.awsRequestId, route: `${method} ${path}`, startedAt: Date.now() };
  try {
    if (method === "POST" && path === "/auth/apple") return sendJSON(stream, 200, await signInWithApple(event, ctx), ctx);
    if (method === "GET" && path === "/credits") return sendJSON(stream, 200, await getCredits(event, ctx), ctx);
    if (method === "GET" && path === "/usage") return sendJSON(stream, 200, await getUsage(event, ctx), ctx);
    if (method === "POST" && path === "/purchase") return sendJSON(stream, 200, await purchase(event, ctx), ctx);
    if (method === "POST" && path === "/promo/redeem") return sendJSON(stream, 200, await redeemPromo(event, ctx), ctx);
    if (method === "DELETE" && path === "/account") return sendJSON(stream, 200, await deleteAccount(event, ctx), ctx);
    if (method === "POST" && path === "/menu") return await menu(event, stream, ctx);
    if (method === "POST" && path === "/image") return sendJSON(stream, 200, await image(event, ctx), ctx);
    if (method === "GET" && path === "/models") return sendJSON(stream, 200, catalogFor(storefrontOf(event)), ctx);
    ctx.route = "unknown"; // don't let random paths explode the metric dimension
    return sendJSON(stream, 404, { error: "not found" }, ctx);
  } catch (e) {
    if (e instanceof HttpError) {
      ctx.error = e.message;
      // OpenAI's error shape, so the app's existing error handling reads it.
      return sendJSON(stream, e.status, { error: { message: e.message, ...e.extra }, ...e.extra }, ctx);
    }
    ctx.error = String(e?.message ?? e);
    logEvent("ERROR", "unhandled error", { requestId: ctx.requestId, route: ctx.route, error: ctx.error, stack: e?.stack });
    if (ctx.status) return;
    return sendJSON(stream, 500, { error: { message: "internal error" } }, ctx);
  } finally {
    await Promise.all(requestScope.getStore().pending);
    const { startedAt, ...fields } = ctx;
    logRequest({ ...fields, ...summarize(requestScope.getStore().ddb), ms: Date.now() - startedAt });
  }
}
