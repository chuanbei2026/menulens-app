// ForeignMenu backend: one Lambda behind a Function URL in RESPONSE_STREAM mode. The app signs in
// with Apple and spends credits; the OpenAI key never leaves the server.
//
//   POST /auth/anonymous { deviceId?, deviceSecret? } → { token, expiresAt, userId, created, signupCredits, deviceId?, deviceSecret? }
//                      a device account, no sign-in (anonymous.mjs); rate-limited per IP (429)
//   POST /auth/apple   { identityToken, authorizationCode? } → { token, expiresAt, userId }
//   POST /auth/apple/link { identityToken, authorizationCode? } (Bearer device session)
//                      → { token, expiresAt, userId, linked: "attach" | "merge" | "already", movedCredits }
//                      moves the device account into the Apple account (merge.mjs)
//   POST /auth/refresh (Bearer)                 → { token, expiresAt, userId } a new 30-day session
//   GET  /credits      (Bearer session token)   → { totalCredits, giftCredits, paidCredits, monthlyGrant, lastGrantPeriod, appAccountToken,
//                                                   subscription: { active, productId, expiresAt, autoRenew, monthUsedCredits, monthFairUseCredits } }
//   GET  /usage        (Bearer)                 → { balance, subscription, days: [{ date, spent, added, calls, covered, balance }] } (last 30 days)
//   POST /purchase     { jws } (Bearer)         → credits a StoreKit 2 purchase
//   POST /subscription { jws, renewalJws? } (Bearer) → records the account's subscription (subscription.mjs)
//   POST /appstore/notifications { signedPayload } → App Store Server Notifications V2; always 200
//   POST /promo/redeem                          → 410 { reason: "retired" } (redeem codes were removed in 1.1 (4))
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
// Subscribers' calls are covered (charged 0) up to the monthly fair use, then charged as usual.
import { randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb";
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import { config } from "./config.mjs";
import { stripPrefix } from "./prefix.mjs";
import { AuthError, issueSessionToken, verifyAppleIdentityToken, verifySessionToken } from "./auth.mjs";
import { CreditStore, InsufficientCredits, PurchaseConflict, balanceHistory, billingPeriod, publicBalance, publicDay, toCredits } from "./credits.mjs";
import { AnonymousAccounts, clientIp, DeviceAuthError, isAnonymous, RateLimited, signupBonusAllowed } from "./anonymous.mjs";
import { MergeError, mergeIntoApple } from "./merge.mjs";
import { accountToken, creditableTransaction, PurchaseError, verifyAppleJWS } from "./purchase.mjs";
import { instrument, newScope, requestScope, summarize } from "./ddbstats.mjs";
import { logEvent, logRequest } from "./log.mjs";
import { chatCostUsd, EXPECTED_IMAGE_OUTPUT_TOKENS, imageCostUsd, tenthsForUsd } from "./pricing.mjs";
import { catalogFor, normalizeStorefront, providerAllowed } from "./regions.mjs";
import { relayBedrockMenu } from "./bedrock.mjs";
import { exchangeCode, revokeToken } from "./appleRevoke.mjs";
import { PurchaseRecords, transactionFacts } from "./purchaseRecords.mjs";
import { handleNotification, publicSubscription, recordEntitlement, SubscriptionConflict, SubscriptionStore } from "./subscription.mjs";
import { generateImage, imageRequest, menuRequest, relayMenu, RequestError, upstreamMessage } from "./relay.mjs";

const ddb = instrument(DynamoDBDocumentClient.from(new DynamoDBClient({})));
const secrets = new SecretsManagerClient({});
const store = new CreditStore(ddb, config);
const purchases = new PurchaseRecords(ddb, config.purchasesTable);
const subs = new SubscriptionStore(ddb, config);
const anonymous = new AnonymousAccounts(ddb, store, config);

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

/** A device account that moved into an Apple account answers 401 "merged": the app signs in again. */
function refuseMerged(item) {
  if (item?.mergedInto) throw new HttpError(401, "this device account moved into an Apple account", { reason: "merged" });
}

async function grant(userId, ctx) {
  const { kind, item } = await store.grantIfDue(userId);
  refuseMerged(item);
  if (kind === "reopen") logEvent("INFO", "account reopened after deletion (no signup bonus)", { requestId: ctx.requestId, userId });
  else if (kind) {
    ctx.grant = kind;
    const what = { signup: "account created", monthly: "monthly grant", subscriber: "subscriber grant" }[kind];
    logEvent("INFO", what, { requestId: ctx.requestId, userId, grant: kind });
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

/** The Apple user id ("apple:<sub>") of a verified identity token. */
async function appleUser(identityToken) {
  try {
    const claims = await verifyAppleIdentityToken(identityToken, { audience: config.appleAudience });
    return `apple:${claims.sub}`;
  } catch (e) {
    if (e instanceof AuthError) throw new HttpError(401, `apple: ${e.message}`);
    throw e;
  }
}

/**
 * Keeps a refresh token so deleting the account can revoke the Apple authorization. Best effort: a
 * failure here never blocks signing in.
 */
async function keepAppleRefreshToken(userId, authorizationCode, ctx) {
  if (typeof authorizationCode !== "string" || !authorizationCode) return;
  const key = await siwaKey();
  if (!key) return;
  try {
    const refresh = await exchangeCode(authorizationCode, key, config.appleAudience[0]);
    if (refresh) await store.setAppleRefreshToken(userId, refresh);
    ctx.appleToken = refresh ? "stored" : "none";
  } catch (e) {
    logEvent("WARN", "apple code exchange failed", { requestId: ctx.requestId, userId, error: String(e.message).slice(0, 200) });
  }
}

async function session(userId) {
  return { ...issueSessionToken(userId, await secretKey(config.sessionSecretArn), { days: config.sessionDays }), userId };
}

async function signInWithApple(event, ctx) {
  const { identityToken, authorizationCode } = readBody(event);
  const userId = await appleUser(identityToken);
  ctx.userId = userId;
  await grant(userId, ctx); // signing in counts as using the service: opens the account / this month's grant
  await keepAppleRefreshToken(userId, authorizationCode, ctx);
  return session(userId);
}

/**
 * Sign in with Apple from a device account: moves it into the Apple account (merge.mjs) and answers
 * with the Apple account's session. Safe to repeat. From an Apple session it is a plain sign-in.
 */
async function linkApple(event, ctx) {
  const current = await authenticate(event);
  const { identityToken, authorizationCode } = readBody(event);
  const appleId = await appleUser(identityToken);
  ctx.userId = appleId;
  if (!isAnonymous(current)) {
    await grant(appleId, ctx);
    await keepAppleRefreshToken(appleId, authorizationCode, ctx);
    return { ...(await session(appleId)), linked: current === appleId ? "already" : "switch", movedCredits: 0 };
  }
  ctx.from = current;
  let result;
  try {
    result = await mergeIntoApple(current, appleId, { ddb, store, subs, purchases, config });
  } catch (e) {
    if (e instanceof MergeError) {
      throw new HttpError(e.reason === "no_account" ? 401 : 409, e.reason === "no_account"
        ? "device account not found" : "device account already moved into another Apple account", { reason: e.reason });
    }
    throw e;
  }
  Object.assign(ctx, { linked: result.kind, creditsMoved: toCredits(result.movedTenths) });
  logEvent("INFO", "device account linked", { requestId: ctx.requestId, userId: appleId, from: current, linked: result.kind,
    creditsMoved: toCredits(result.movedTenths) });
  await grant(appleId, ctx); // the subscriber grant, if the move brought an active subscription
  await keepAppleRefreshToken(appleId, authorizationCode, ctx);
  return { ...(await session(appleId)), linked: result.kind, movedCredits: Math.floor(toCredits(result.movedTenths)) };
}

/** POST /auth/anonymous: a device account and its session (anonymous.mjs). */
async function signInAnonymously(event, ctx) {
  const body = readBody(event);
  let r;
  try {
    r = await anonymous.open(body, { ip: clientIp(event), bonusAllowed: await signupBonusAllowed({ event, body }) });
  } catch (e) {
    if (e instanceof DeviceAuthError) throw new HttpError(401, e.message, { reason: "device" });
    if (e instanceof RateLimited) throw new HttpError(429, e.message, { reason: "rate_limited" });
    throw e;
  }
  ctx.userId = r.userId;
  if (r.created) {
    ctx.grant = r.signupCredits > 0 ? "signup" : "none";
    logEvent("INFO", "device account created", { requestId: ctx.requestId, userId: r.userId, signupCredits: r.signupCredits,
      ...(r.predecessor ? { predecessor: r.predecessor } : {}) });
  }
  return {
    ...(await session(r.userId)), created: r.created, signupCredits: r.signupCredits,
    ...(r.created ? { deviceId: r.userId, deviceSecret: r.deviceSecret } : {}),
  };
}

/** POST /auth/refresh: a new 30-day session for a still-valid one (Apple accounts have no device secret). */
async function refreshSession(event, ctx) {
  const userId = await authenticate(event);
  ctx.userId = userId;
  const item = await store.read(userId);
  if (!item) throw new HttpError(401, "account not found", { reason: "deleted" });
  refuseMerged(item);
  return session(userId);
}

async function deleteAccount(event, ctx) {
  const userId = await authenticate(event);
  ctx.userId = userId;
  // Revoke the Apple authorization first (guideline 5.1.1(v)); the account goes either way. Device
  // accounts have no Apple identity and nothing to revoke.
  const token = isAnonymous(userId) ? null : await store.appleRefreshToken(userId);
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
  logEvent("INFO", "account deleted", { requestId: ctx.requestId, userId, anonymous: isAnonymous(userId) });
  return { deleted: true };
}

function emptyBalance() {
  return { total: 0, gift: 0, paid: 0, monthlyGrant: config.monthlyGrant };
}

function subscriptionOf(item, now = new Date()) {
  return publicSubscription(item, { now, period: billingPeriod(now, config.billingTimeZone), fairUseCredits: config.subscriberMonthlyFairUse });
}

async function getCredits(event, ctx) {
  const userId = await authenticate(event); // viewing the balance is not "use": no grant here
  ctx.userId = userId;
  const item = await store.read(userId);
  refuseMerged(item);
  const b = store.toBalance(item) ?? emptyBalance();
  return { ...publicBalance(b), appAccountToken: accountToken(userId), subscription: subscriptionOf(item) };
}

async function getUsage(event, ctx) {
  const userId = await authenticate(event);
  ctx.userId = userId;
  const [item, rows] = await Promise.all([store.read(userId), store.dailyRows(userId, config.usageDays)]);
  refuseMerged(item);
  const balance = store.toBalance(item) ?? emptyBalance();
  const days = balanceHistory(rows, { balance: balance.total, days: config.usageDays, timeZone: config.billingTimeZone });
  return { balance: publicBalance(balance), subscription: subscriptionOf(item), days: days.map(publicDay) };
}

async function purchase(event, ctx) {
  const userId = await authenticate(event);
  ctx.userId = userId;
  const { jws } = readBody(event);
  let payload = null;
  try {
    payload = verifyAppleJWS(jws);
    const account = (await grant(userId, ctx)) ?? await store.read(userId);
    const tx = creditableTransaction(payload, { userId, aliases: account?.mergedFrom, bundleId: config.appBundleId,
      allowSandbox: config.allowSandboxPurchases });
    const result = await store.creditPurchase(userId, tx);
    const facts = transactionFacts(payload);
    await purchases.record(userId, { ...facts, credits: result.credits, bonus: result.bonus ?? 0,
      status: result.credited ? "credited" : "duplicate" });
    logEvent("INFO", "purchase", { requestId: ctx.requestId, userId, productId: tx.productId, environment: tx.environment,
      credits: result.credits, credited: result.credited, price: facts.price, currency: facts.currency, storefront: facts.storefront,
      ...(facts.offerType !== undefined ? { offerType: facts.offerType, offerIdentifier: facts.offerIdentifier } : {}) });
    return { ...result, productId: tx.productId, ...publicBalance(await store.balance(userId)) };
  } catch (e) {
    const reason = e instanceof PurchaseError ? e.reason : e instanceof PurchaseConflict ? "conflict" : null;
    if (reason) {
      // Rejected attempts are kept too: they explain "I paid but got nothing" tickets.
      await purchases.record(userId, { ...transactionFacts(payload), status: "rejected", reason });
      logEvent("WARN", "purchase rejected", { requestId: ctx.requestId, userId, reason });
    }
    if (e instanceof PurchaseError) throw new HttpError(400, e.reason, { reason: e.reason });
    if (e instanceof PurchaseConflict) throw new HttpError(409, "purchase belongs to another account", { reason: "conflict" });
    throw e;
  }
}

/**
 * The app's current subscription entitlement (after a purchase, and on every launch / foreground):
 * verified like a purchase, linked to this account, merged into its state. Idempotent. The first
 * use in a month while subscribed also brings the subscriber grant.
 */
async function subscribe(event, ctx) {
  const userId = await authenticate(event);
  ctx.userId = userId;
  try {
    const account = await store.read(userId);
    refuseMerged(account);
    const r = await recordEntitlement(readBody(event), {
      userId, aliases: account?.mergedFrom, verify: (jws) => verifyAppleJWS(jws), subs, records: purchases, grant: (u) => grant(u, ctx),
      read: (u) => store.read(u), bundleId: config.appBundleId, allowSandbox: config.allowSandboxPurchases,
    });
    ctx.subscription = r.productId;
    if (r.isNew) {
      const p = r.payload;
      logEvent("INFO", "subscription", { requestId: ctx.requestId, userId, productId: r.productId, environment: p.environment,
        expiresAt: r.after.expiresAt, price: typeof p.price === "number" ? p.price / 1000 : undefined, currency: p.currency, storefront: p.storefront });
    }
    return { subscription: subscriptionOf(r.item), ...publicBalance(store.toBalance(r.item) ?? emptyBalance()) };
  } catch (e) {
    const reason = e instanceof PurchaseError ? e.reason : e instanceof SubscriptionConflict ? "conflict" : null;
    if (reason) {
      // Rejected attempts are kept too, like purchases.
      await purchases.record(userId, { ...transactionFacts(e.payload), type: "subscription", status: "rejected", reason });
      logEvent("WARN", "subscription rejected", { requestId: ctx.requestId, userId, reason });
    }
    if (e instanceof PurchaseError) throw new HttpError(400, e.reason, { reason: e.reason });
    if (e instanceof SubscriptionConflict) throw new HttpError(409, "subscription belongs to another account", { reason: "conflict" });
    throw e;
  }
}

/** App Store Server Notifications V2. Always 200: Apple retries anything else for days. */
async function appStoreNotification(event, ctx) {
  let body = {};
  try { body = readBody(event); } catch { /* answered 200 below */ }
  const summary = await handleNotification(body, {
    verify: (jws) => verifyAppleJWS(jws), subs, records: purchases,
    bundleId: config.appBundleId, allowSandbox: config.allowSandboxPurchases,
  });
  Object.assign(ctx, { userId: summary.userId, notification: summary.type, subtype: summary.subtype, ignored: summary.ignored });
  logEvent("INFO", "app store notification", { requestId: ctx.requestId, ...summary });
  return { ok: true };
}

/**
 * Redeem codes were removed in 1.1 (4) (App Review 3.1.1: an in-app code that adds credits unlocks
 * paid content). Credits already redeemed stay; giveaways use App Store Offer Codes, which arrive as
 * ordinary purchases (POST /purchase).
 */
function redeemRetired() {
  throw new HttpError(410, "redeem codes are no longer available", { reason: "retired" });
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

/**
 * Reserves a call's worst case: covered by an active subscription while under this month's fair use,
 * otherwise from the balance (reserve). The split says which (split.covered).
 */
async function charge(userId, tenths, ref, account, ctx) {
  const { split, reason } = await store.reserveCovered(userId, tenths, ref, account);
  if (split) {
    Object.assign(ctx, { ref, creditsReserved: 0, covered: true });
    return split;
  }
  if (reason === "fair_use") ctx.overFairUse = true;
  return reserve(userId, tenths, ref, account, ctx);
}

/** Tenths a split holds, covered or charged. */
const reservedTenths = (split) => split.fromGift + split.fromPaid + (split.covered ?? 0);

/** Logged and reported amounts of a settled call: charged credits, and what a subscription covered. */
function settledAmounts(split, actual) {
  return split.covered !== undefined ? { charged: 0, covered: actual } : { charged: actual, covered: 0 };
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
  const split = await charge(userId, worst, ref, account, ctx);

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
  const actual = result.usage ? tenthsForUsd(chatCostUsd(req.model, result.usage)) : reservedTenths(split);
  const amounts = settledAmounts(split, actual);
  Object.assign(ctx, {
    creditsCharged: toCredits(amounts.charged), creditsCovered: toCredits(amounts.covered), finishReason: result.finishReason ?? "unknown",
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
    write(`event: foreignmenu.credits\ndata: ${JSON.stringify({ charged: Math.round(toCredits(amounts.charged)),
      covered: Math.round(toCredits(amounts.covered)), totalCredits, giftCredits, paidCredits })}\n\n`);
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
  const split = await charge(userId, worst, ref, account, ctx);
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
  const actual = result.usage ? tenthsForUsd(imageCostUsd(result.usage)) : reservedTenths(split);
  const amounts = settledAmounts(split, actual);
  Object.assign(ctx, {
    creditsCharged: toCredits(amounts.charged), creditsCovered: toCredits(amounts.covered), inputTokens: (result.usage?.text ?? 0) + (result.usage?.image ?? 0),
    outputTokens: result.usage?.output ?? 0, costUsd: result.usage ? Number(imageCostUsd(result.usage).toFixed(6)) : 0,
  });
  await store.settle(userId, split, actual, ref);
  const b = await store.balance(userId);
  ctx.creditsLeft = toCredits(b.total);
  const { totalCredits } = publicBalance(b);
  return { ...result.json, credits: { charged: Math.round(toCredits(amounts.charged)), covered: Math.round(toCredits(amounts.covered)), totalCredits } };
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
  // Behind CloudFront every route arrives under /menu (api.chuanbei.dev/menu/… → this Lambda;
  // CloudFront can route by prefix but not strip it). Builds that call the Lambda URL directly send
  // the bare path, so both work.
  event.rawPath = stripPrefix(event.rawPath ?? "/");
  const path = event.rawPath;
  const ctx = { requestId: context?.awsRequestId, route: `${method} ${path}`, startedAt: Date.now() };
  try {
    if (method === "POST" && path === "/auth/anonymous") return sendJSON(stream, 200, await signInAnonymously(event, ctx), ctx);
    if (method === "POST" && path === "/auth/apple") return sendJSON(stream, 200, await signInWithApple(event, ctx), ctx);
    if (method === "POST" && path === "/auth/apple/link") return sendJSON(stream, 200, await linkApple(event, ctx), ctx);
    if (method === "POST" && path === "/auth/refresh") return sendJSON(stream, 200, await refreshSession(event, ctx), ctx);
    if (method === "GET" && path === "/credits") return sendJSON(stream, 200, await getCredits(event, ctx), ctx);
    if (method === "GET" && path === "/usage") return sendJSON(stream, 200, await getUsage(event, ctx), ctx);
    if (method === "POST" && path === "/purchase") return sendJSON(stream, 200, await purchase(event, ctx), ctx);
    if (method === "POST" && path === "/subscription") return sendJSON(stream, 200, await subscribe(event, ctx), ctx);
    if (method === "POST" && path === "/appstore/notifications") return sendJSON(stream, 200, await appStoreNotification(event, ctx), ctx);
    if (method === "POST" && path === "/promo/redeem") return redeemRetired();
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
