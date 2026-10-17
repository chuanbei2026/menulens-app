# ForeignMenu backend

One Lambda (Node.js, Function URL in `RESPONSE_STREAM` mode) so the app no longer needs the user's own
OpenAI key: Sign in with Apple → our session token → per-user credits → relay to OpenAI with our key.
Same design as the DateSeries backend, with its own tables, secrets and credits.

```
App ──POST /auth/apple {identityToken}──► verify Apple JWT ──► 30-day session token (HS256)
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
| Apple / session tokens, credits, purchases, logging | `src/auth.mjs`, `src/credits.mjs`, `src/purchase.mjs`, `src/log.mjs` (shared with DateSeries) |

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

Live: `https://uwondrk7ngmf3jgkimsifwa62q0fwgzo.lambda-url.us-west-2.on.aws/`

- OpenAI key: secret `AwsLambdaKey/foreign-menu` (`{"key": …}`). Session key: `foreignmenu/session-key`.
- Logs: `/aws/lambda/foreignmenu-api` (90 days), one JSON line per request with sizes, tokens, `costUsd` and
  credits; metrics in the `ForeignMenu` namespace; saved queries under **ForeignMenu/**.
  **Never logged:** menu photos, text, prompts, model output, tokens or secrets.
- Lambda concurrency is shared with DateSeries (the account limit is 10); a big scan uses several at once.
