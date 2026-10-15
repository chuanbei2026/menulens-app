# ForeignMenu backend

One Lambda (Node.js, Function URL in `RESPONSE_STREAM` mode) so the app no longer needs the user's own
OpenAI key: Sign in with Apple → our session token → per-user credits → relay to OpenAI with our key.
Same design as the DateSeries backend, with its own tables, secrets and credits.

```
App ──POST /auth/apple {identityToken}──► verify Apple JWT ──► 30-day session token (HS256)
App ──GET  /credits ─────────────────────► balance (lazy monthly grant happens on use)
App ──POST /menu  (Chat Completions body)─► reserve estimate ──► OpenAI stream, bytes unchanged ──► settle usage
App ──POST /image {prompt} ──────────────► reserve estimate ──► gpt-image-1-mini (1024², low, jpeg) ──► settle usage
```

| Piece | Where |
|---|---|
| Config (tables, secrets, grants, US$ per credit, output cap) | `src/config.mjs` |
| List prices and credit math | `src/pricing.mjs` |
| Request shaping, SSE usage sniffing, image call | `src/relay.mjs` |
| Routes | `src/index.mjs` |
| Apple / session tokens, credits, purchases, logging | `src/auth.mjs`, `src/credits.mjs`, `src/purchase.mjs`, `src/log.mjs` (shared with DateSeries) |

## Credits

- **Free:** 300 at signup, no monthly grant (unlike DateSeries); after that users buy credits. Nothing expires.
- **Price:** every call is charged its OpenAI list cost at **US$0.005 a credit**, rounded up to 0.1 credit
  (at least 0.1). A menu page on gpt-4.1 is ~5–10 credits; a low-quality 2×2 collage of dish pictures (gpt-image-1-mini) ~0.5.
- Stored in tenths; the API returns whole credits. Out of credits → **402** `{reason: "credits", totalCredits, needed}`.
- Purchases (`POST /purchase`, StoreKit 2 JWS): `ai.xiangyang.MenuLens.credits.{100,500,2000}` at US$0.99 / 4.99 / 19.99
  give 110 / 550 / 2200 (+10%), the same packs as DateSeries — ~35% margin after Apple's 15%.

The server picks what reaches OpenAI: the model must be one of `MODELS` in `src/pricing.mjs`
(default `gpt-4.1`), output is capped, images are pinned to gpt-image-1-mini 1024² low-quality jpeg.

## Deploy / test

```bash
npm install && npm test                                                # unit tests, no AWS
AWS_PROFILE=claude-agent ./deploy.sh                                   # idempotent
AWS_PROFILE=claude-agent node scripts/live-test.mjs <function-url>     # end to end, ~US$0.015
```

Live: `https://uwondrk7ngmf3jgkimsifwa62q0fwgzo.lambda-url.us-west-2.on.aws/`

- OpenAI key: secret `AwsLambdaKey/foreign-menu` (`{"key": …}`). Session key: `foreignmenu/session-key`.
- Logs: `/aws/lambda/foreignmenu-api` (90 days), one JSON line per request with sizes, tokens, `costUsd` and
  credits; metrics in the `ForeignMenu` namespace; saved queries under **ForeignMenu/**.
  **Never logged:** menu photos, text, prompts, model output, tokens or secrets.
- Lambda concurrency is shared with DateSeries (the account limit is 10); a big scan uses several at once.
