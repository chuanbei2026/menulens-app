# ForeignMenu backend

One Lambda (Node.js, Function URL in `RESPONSE_STREAM` mode) so the app no longer needs the user's own
OpenAI key: a device account (or Sign in with Apple) → our session token → per-user credits → relay to
OpenAI with our key. Same design as the DateSeries backend, with its own tables, secrets and credits.

```
App ──POST /auth/anonymous {deviceId?, deviceSecret?}─► device account ──► 30-day session token (HS256)
App ──POST /auth/apple {identityToken}──► verify Apple JWT ──► 30-day session token (HS256)
App ──POST /auth/apple/link (Bearer device session) ──► move the device account into the Apple account
App ──GET  /credits ─────────────────────► balance (lazy monthly grant happens on use)
App ──POST /menu  (Chat Completions body)─► reserve estimate ──► OpenAI stream, bytes unchanged ──► settle usage
App ──POST /image {prompt} ──────────────► reserve estimate ──► gpt-image-1-mini (1024², low, jpeg) ──► settle usage
App ──POST /subscription {jws} ──────────► verify StoreKit JWS ──► subscription state on the account
Apple ─POST /appstore/notifications ─────► verify signedPayload ──► renewals / expiry / grace / refunds
```

| Piece | Where |
|---|---|
| Config (tables, secrets, grants, US$ per credit, output cap) | `src/config.mjs` |
| List prices and credit math | `src/pricing.mjs` |
| Request shaping, SSE usage sniffing, image call | `src/relay.mjs` |
| Routes | `src/index.mjs` |
| Subscriptions: state, covered calls, Server Notifications | `src/subscription.mjs` (+ `reserveCovered` / `subscriberGrant` in `src/credits.mjs`) |
| Device accounts, per-IP signup limit | `src/anonymous.mjs` |
| Moving a device account into an Apple account | `src/merge.mjs` |
| Apple / session tokens, credits, purchases, logging | `src/auth.mjs`, `src/credits.mjs`, `src/purchase.mjs`, `src/log.mjs` (shared with DateSeries) |

## Accounts (1.1 (4): no sign-in needed)

App Review (guideline 5.1.1(v)) wants scanning without registering, so every install gets an
**anonymous device account** on first launch; Sign in with Apple is optional.

| Route | What it does |
|---|---|
| `POST /auth/anonymous {}` | New account `anon:<uuid>` with the normal **300** signup credits. Returns the session plus `deviceId` / `deviceSecret`, which the app keeps in the Keychain (this device only, survives a reinstall). **Rate-limited per IP**: `ANON_SIGNUPS_PER_IP_HOUR` = 10, `ANON_SIGNUPS_PER_IP_DAY` = 30 (counters in the promo table, `rate#anon#<ip hash>`, TTL `expiresEpoch`; the IP itself isn't stored). 429 `{reason: "rate_limited"}` beyond that. |
| `POST /auth/anonymous {deviceId, deviceSecret}` | A fresh 30-day session for that account (not rate-limited). Wrong secret → 401 `{reason: "device"}`. If the account was moved into an Apple account or deleted, a **new device account with 0 credits** (`predecessor` recorded). |
| `POST /auth/refresh` (Bearer) | A new 30-day session for a still-valid one (Apple accounts have no device secret). |
| `POST /auth/apple` | Unchanged: Sign in with Apple without a device account (builds before 1.1 (4)). |
| `POST /auth/apple/link {identityToken, authorizationCode?}` (Bearer device session) | Moves the device account into `apple:<sub>` and returns the Apple account's session: `linked: "attach"` (the Apple ID was new: its account is opened with the device balance, **no new 300**), `"merge"` (added to the existing account), `"already"` (a retry). From an Apple session it's a plain sign-in (`"switch"`). 409 `conflict` if the device account already went into a different Apple account. |

**Repeated free credits** are held back only by the Keychain (the app reuses its device secret, and a
device whose account was moved or deleted gets 0 next time) and by the per-IP limit. Calling the API
directly or wiping the device gets another 300. TODO(DeviceCheck): `signupBonusAllowed` in
`src/anonymous.mjs` is the one hook to check a DeviceCheck token before the bonus.

**The move (`src/merge.mjs`)**, the same for attach and merge:

1. One DynamoDB transaction: the device account is closed (balance 0, `mergedInto`), the Apple account
   gains the whole balance (gift and paid as they are) and lists the device account in `mergedFrom`,
   ledger `merge_out` / `merge_in` entries on both sides and the Apple account's daily rollup. Conditional
   on both accounts' `version`, so a charge in between makes it re-read. The device's subscription state is
   copied when it runs longer than the Apple account's.
2. Idempotent clean-up: subscription links `sub#<originalTransactionId>`, credited-purchase markers
   `iap#<transactionId>` and the purchases-table rows (`movedFrom`) are re-pointed to the Apple account;
   the device account's daily rows are dropped. Not carried: its 30-day chart and this month's fair-use meter.

A retry finds `mergedInto` set and only redoes step 2 (and sweeps a refund that settled into the closed
account meanwhile). A stale device session gets 401 `{reason: "merged"}` everywhere. StoreKit keeps the
device account's `appAccountToken` on its transactions forever, so `/purchase`, `/subscription` and the
notifications accept the tokens of every `mergedFrom` account; a subscription link still held by a merged
device account is taken over.

**Deleting** works the same for device accounts (no Apple authorization to revoke) and leaves the hashed
tombstone. User ids stay pseudonymous (`anon:<uuid>` / `apple:<sub>`), linked to the account's balance and
purchases — the App Store privacy label keeps **User ID: linked**.

**Redeem codes are retired** (guideline 3.1.1): `POST /promo/redeem` answers **410** `{reason: "retired"}`;
credits already redeemed stay. Giveaways use App Store Connect **Offer Codes** for the credit packs: a
redemption arrives in the app as an ordinary transaction (`Transaction.updates`, `offerType` 3, often
price 0, usually without `appAccountToken`) and `POST /purchase` credits it once per transaction like any
purchase; `offerType` / `offerIdentifier` are kept in the purchases table. `scripts/promo.mjs` stays only to
look at or disable the old codes.

## Credits

- **Free:** 300 at signup, no monthly grant (unlike DateSeries); after that users buy credits. Nothing expires.
- **Price:** every call is charged its OpenAI list cost at **US$0.005 a credit**, rounded up to 0.1 credit
  (at least 0.1). A menu page on gpt-4.1 is ~5–10 credits; a low-quality 2×2 collage of dish pictures (gpt-image-1-mini) ~0.5.
- Stored in tenths; the API returns whole credits. Out of credits → **402** `{reason: "credits", totalCredits, needed}`.
- Purchases (`POST /purchase`, StoreKit 2 JWS): `ai.xiangyang.MenuLens.credits.{100,500,2000}` at US$0.99 / 4.99 / 19.99
  give 100 / 500 / 2000 (no bonus, unlike DateSeries) — ~40% margin after Apple's 15%.

## Subscriptions (1.2 — deploy after the 1.1 review)

One auto-renewable group, **ForeignMenu Membership**: `ai.xiangyang.MenuLens.sub.monthly` / `.quarterly` / `.yearly`
at US$4 / 10 / 30. Credit packs and the 300 at signup stay exactly as they are for everyone else.

- **Covered calls.** While a subscription is active, `/menu` and `/image` charge nothing: the worst case is reserved
  against a per-month counter on the account (`coveredPeriod` / `coveredTenths`, billing month in America/Vancouver)
  instead of the balance, and settled to the real cost — the same reserve/settle shape, race-safe through a
  conditional update. Up to **`SUBSCRIBER_MONTHLY_FAIR_USE` = 600 credits' worth per month**; a call that doesn't fit
  is charged from the balance as usual (402 when that is empty too). The ledger records covered calls as a hold and a
  settle that move nothing (`chargedTenths: 0`, `coveredTenths`: what it would have cost) and the daily rollup adds
  `coveredTenths`, so usage stats stay complete. `costUsd` is logged as for any call; metrics `CreditsCovered`,
  `OverFairUse`, `SubscriberGrants`, `StoreNotifications`.
- **Monthly grant.** +`SUBSCRIBER_MONTHLY_GRANT` = 50 gift credits in each billing month an active subscriber uses the
  app (first use; own marker `subGrantPeriod`). The everyone-grant stays 0.
- **State** lives on the account item (`subscription`: productId, originalTransactionId, transactionId, expiresAt,
  graceExpiresAt, autoRenew, environment, revokedAt, status, lastVerifiedAt; `subSeq` for optimistic locking).
  Active = not revoked and before `expiresAt` (or the end of a billing grace period). Merging is order-independent:
  the longest-running transaction wins, a refund revokes only the current transaction, newer renewal info wins.
- **`POST /subscription { jws, renewalJws? }`** (Bearer): the app sends its current entitlement after a purchase and on
  every launch / foreground. Same verification as purchases (pinned Apple root, receipt-signing leaf), then: one of
  our subscription ids, our bundle id, the account's `appAccountToken`, not revoked, sandbox only while
  `ALLOW_SANDBOX_PURCHASES=1`. Idempotent. Links `originalTransactionId → userId` in the promo table
  (`sub#<originalTransactionId>` / `#subscription`): one Apple subscription belongs to one account (409 `conflict`
  otherwise). New transactions are kept in the purchases table with `type: "subscription"`.
- **`POST /appstore/notifications`** — App Store Server Notifications V2, no session. `signedPayload` and the nested
  `signedTransactionInfo` / `signedRenewalInfo` are verified with the same chain. Handles SUBSCRIBED, DID_RENEW,
  DID_CHANGE_RENEWAL_STATUS, EXPIRED, DID_FAIL_TO_RENEW (grace period), REFUND, REVOKE (and merges anything else that
  carries a transaction). Unknown subscriptions, other apps, sandbox while it's off, credit-pack notifications and
  forgeries are logged and ignored. **Always answers 200** (Apple retries anything else for days).
  URL for App Store Connect (Production and Sandbox): `https://api.chuanbei.dev/menu/appstore/notifications`
  (CloudFront's `/menu/*` behavior → this Lambda; `src/prefix.mjs` strips `/menu`).
- **`GET /credits`** and **`GET /usage`** add `subscription: { active, productId, expiresAt, autoRenew, monthUsedCredits,
  monthFairUseCredits }` (whole credits); `/usage` days add `covered`.

The server picks what reaches OpenAI: the model must be one of `MODELS` in `src/pricing.mjs`
(default `gpt-4.1`), output is capped, images are pinned to gpt-image-1-mini 1024² low-quality jpeg.

## Deploy / test

```bash
npm install && npm test                                                # unit tests, no AWS (handler.test.mjs drives index.mjs on fakes)
AWS_PROFILE=claude-agent ./deploy.sh                                   # idempotent
AWS_PROFILE=claude-agent node scripts/live-test.mjs <function-url>     # end to end, ~US$0.015
```

Live: `https://uwondrk7ngmf3jgkimsifwa62q0fwgzo.lambda-url.us-west-2.on.aws/`; from 1.1 (4) the app calls
`https://api.chuanbei.dev/menu/…` (CloudFront's `/menu/*` behavior → this Lambda, `src/prefix.mjs` strips
`/menu`; a bare `/menu` is the scan route itself).

- OpenAI key: secret `AwsLambdaKey/foreign-menu` (`{"key": …}`). Session key: `foreignmenu/session-key`.
- Logs: `/aws/lambda/foreignmenu-api` (**30 days**), one JSON line per request; metrics in the `ForeignMenu`
  namespace; saved queries under **ForeignMenu/**. See **Logs, metrics, alarms** below.
  **Never logged:** menu photos, text, prompts, model output, Apple / session tokens, device secrets or IP addresses
  (the per-IP limit stores only a hash, in DynamoDB).
- Lambda concurrency is shared with DateSeries (the account pool is 1000); a big scan uses several at once.

## Logs, metrics, alarms

Every request writes **one JSON line**: `requestId, route, status, ms, accountKind (anon | apple | dev | none), userId`
and the DynamoDB work (`ddbCalls, ddbMs, ddbCapacityUnits, ddbConditionalFailures, ddbErrors, ddbRetries`); model calls
add `model, provider, storefront, inputTokens, cachedTokens, outputTokens, costUsd, ttfbMs, creditsCharged,
creditsCovered, creditsLeft, upstreamStatus, upstreamError?`; accounts add `grant, creditsGranted, linked, from,
creditsMoved, rateLimited, region`; purchases and subscriptions `productId, price, currency, offer, creditsPurchased,
subActive, rejectReason`; notifications `notification, subtype, ignored, outcome`. Event lines (`device account
created`, `device account linked`, `purchase`, `app store notification`, settlement failures…) carry the same `requestId`.
Upstream error messages are OpenAI's own words (never the request), cut to 300 characters.

The request lines carry CloudWatch Embedded Metric Format (`src/log.mjs`, tested in `test/log.test.mjs` and
`test/handler.test.mjs`). Dimensions are a small fixed vocabulary, never user ids:

| Dimensions | Metrics |
|---|---|
| `route`, and all routes | `Requests, ServerErrors, ClientErrors, LatencyMs, TimeToFirstByteMs, InputTokens, CachedTokens, OutputTokens, CostUsd, ModelCalls, ModelErrors, CreditsCharged, CreditsCovered, OverFairUse, CreditsGranted, CreditsMoved, Signups, SignupsWithoutBonus, SubscriberGrants, MonthlyGrants, StoreNotifications, AnonRateLimited (429), RegionRefusals (403), RedeemGone (410), AppleRevokeSkipped/Failed, AppleTokenSkipped/Failed, Ddb*` (incl. `DdbRetries`) |
| `accountKind` | `Requests, Signups, SignupsWithoutBonus` |
| `model`; `provider` (openai, bedrock) | `ModelCalls, ModelErrors, CostUsd, InputTokens, OutputTokens, TimeToFirstByteMs, LatencyMs` |
| `linked` (attach, merge, already, switch) | `AccountLinks` |
| `productId`, and all products | `Purchases, OfferRedemptions, CreditsPurchased` (credited packs; new subscription transactions) |
| `currency` | `Revenue` (price in the customer's currency, before Apple's commission) |
| `notificationType`; `outcome` (applied, a reason like unknown_subscription, or error) | `StoreNotifications` |
| `subStatus` (active, inactive) | `SubscriptionUpdates` |
| `rejectReason` | `PurchaseRejections` |

Plus a log metric filter `ErrorEvents` (ERROR event lines that aren't request lines). Not measurable here: the app's
coverage retry of a menu scan (`OpenAIClient.Coverage`) is a second, ordinary `POST /menu`; the server can't tell it apart.

```bash
AWS_PROFILE=claude-agent ./observability.sh   # retention, metric filter, saved queries, alarms.sh, dashboard (deploy.sh runs it)
AWS_PROFILE=claude-agent ./alarms.sh          # alarms + SNS topic only
```

- **Dashboard** CloudWatch → Dashboards → **ForeignMenu**: a runbook text widget (links to every saved query with its
  time range), money (Logs Insights), traffic / errors / latency p50-p95-p99, AI cost per day and per model, calls and
  upstream errors per provider, signups (Apple vs device), links and merges, purchases / revenue / membership, the
  credits economy, Lambda, DynamoDB, CloudFront (us-east-1) and an alarm status strip.
- **Saved queries** (folder **ForeignMenu/**): recent requests, errors (last hour), slow requests, one account / one
  request (edit the id), AI upstream failures, cost and credits, cost by model per day, menu latency percentiles,
  purchases, subscription notifications, notifications by type and outcome, merges, rate-limit hits, device accounts
  created, region refusals, out of credits (402), contention and retries.
- **Alarms** (`alarms.sh`, thresholds are env vars) → SNS topic **`chuanbei-ops-alerts`** (us-west-2, shared with
  DateSeries). The CloudFront 5xx alarm and the cost budget are in the DateSeries repo (`infra/backend/alarms.sh`).

  | Alarm | Fires when |
  |---|---|
  | `ForeignMenu-5xx-rate` | 5xx > 10% of requests (and ≥ 3) in 15 min |
  | `ForeignMenu-lambda-errors` | ≥ 2 Lambda errors (crash / timeout) in 15 min |
  | `ForeignMenu-lambda-throttles` | any throttle in 5 min |
  | `ForeignMenu-menu-p95-latency` | `/menu` p95 ≥ 120 s for 2 × 15 min (normal ≈ 40 s) |
  | `ForeignMenu-image-p95-latency` | `/image` p95 ≥ 45 s for 2 × 15 min (normal ≈ 11 s) |
  | `ForeignMenu-ai-upstream-errors` | ≥ 3 failed model calls in 15 min |
  | `ForeignMenu-ai-cost-daily` | AI cost ≥ US$10 in 24 h (`DAILY_AI_COST_USD`) |
  | `ForeignMenu-dynamodb-throttles` | accounts / ledger throttle events or any DynamoDB error a request saw, in 5 min |
  | `ForeignMenu-store-notification-failures` | a notification failed on our side (answered 200, so Apple won't retry) |
  | `ForeignMenu-error-events` | an ERROR event line (settlement, ledger, purchase record…) |
  | `ForeignMenu-anon-signup-limit` | ≥ 20 device-account signups refused by the per-IP limit in an hour |

  Nobody is subscribed by the script. To receive them (confirm the email AWS sends):

  ```bash
  AWS_PROFILE=claude-agent aws sns subscribe --region us-west-2 --topic-arn arn:aws:sns:us-west-2:253490784328:chuanbei-ops-alerts --protocol email --notification-endpoint <your email>
  ```
