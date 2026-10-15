// All tunables in one place. Values come from Lambda environment variables (set by deploy.sh).

export const config = {
  accountsTable: process.env.ACCOUNTS_TABLE ?? "foreignmenu-accounts",
  ledgerTable: process.env.LEDGER_TABLE ?? "foreignmenu-ledger",
  promoTable: process.env.PROMO_TABLE ?? "foreignmenu-promo",
  dailyTable: process.env.DAILY_TABLE ?? "foreignmenu-usage-daily",
  // The OpenAI key: a secret holding either {"key": "sk-…"} or the bare key.
  openAISecretId: process.env.OPENAI_SECRET_ID ?? "AwsLambdaKey/foreign-menu",
  sessionSecretArn: process.env.SESSION_SECRET_ARN,
  // Sign in with Apple key for revoking tokens on account deletion: {"teamId","keyId","privateKey"}.
  siwaSecretId: process.env.SIWA_SECRET_ID ?? "foreignmenu/siwa-key",

  // Sign in with Apple: the identity token's audience is the app's bundle id.
  appleAudience: (process.env.APPLE_AUDIENCE ?? "ai.xiangyang.MenuLens").split(","),
  // In-app purchases: the transaction's bundle id, and whether sandbox purchases (TestFlight, free for
  // testers) are credited. Turn sandbox off once purchases are live on the App Store.
  appBundleId: process.env.APP_BUNDLE_ID ?? "ai.xiangyang.MenuLens",
  allowSandboxPurchases: (process.env.ALLOW_SANDBOX_PURCHASES ?? "1") === "1",
  sessionDays: 30,

  // Credits. 300 free at signup and no monthly grant (unlike DateSeries); after that users buy credits
  // in the app (purchase.mjs). Credits never expire.
  monthlyGrant: Number(process.env.MONTHLY_GRANT ?? 0),
  signupBonus: Number(process.env.SIGNUP_BONUS ?? 300),
  // What one credit buys at OpenAI list price (same basis as DateSeries: US$0.005). Every request is
  // charged its real cost, rounded up to the next 0.1 credit, at least 0.1. One menu page on gpt-4.1
  // is ~US$0.025–0.05 (5–10 credits; a dense page measured 5); a 2×2 collage of dish pictures on
  // gpt-image-1-mini ~US$0.0025 (~0.5 credit).
  usdPerCredit: Number(process.env.USD_PER_CREDIT ?? 0.005),
  usageDays: 30,
  // Calendar month boundaries are computed in this zone, so changing the phone's
  // time zone cannot trigger an extra monthly grant.
  billingTimeZone: "America/Vancouver",

  // The server decides the model and caps the output (cost control); the app may pick from MODELS.
  defaultModel: process.env.OPENAI_MODEL ?? "gpt-4.1",
  maxOutputTokens: 32000,
  // Bedrock's Converse caps differ per model; Mistral Large 3 wrote ~10k for a dense page.
  maxBedrockOutputTokens: 16000,
  // Reserved up front for a menu page before the real usage is known (an overrun is taken afterwards).
  expectedOutputTokens: 8000,
  maxRequestBytes: 6_000_000, // the Lambda URL's own limit
  maxImagesPerRequest: 2,
  maxPromptChars: 4000,
};
