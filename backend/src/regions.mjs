// Which models a user may use, by App Store storefront (StoreKit `Storefront.countryCode`, ISO 3166-1
// alpha-3, sent by the app). The App Store availability list is the primary control — these storefronts
// are delisted — and this is the second line: a request from one of them never reaches a provider that
// doesn't serve it.
//
// 2026-10-15: OpenAI's API is offered only in its listed countries (help.openai.com 5347006; allowlist,
// "offering access" elsewhere can get the account suspended). Mainland China also needs a CAC filing for
// any generative-AI service, whatever the model, and sanctioned countries are out for every provider.
// Extra codes can be added without a deploy-time code change: OPENAI_BLOCKED_STOREFRONTS="AFG,VEN".

import { DEFAULT_MODEL, FALLBACK_MODEL, MODELS } from "./pricing.mjs";

const list = (s) => new Set(String(s ?? "").split(",").map((c) => c.trim().toUpperCase()).filter(Boolean));

/** No model at all: CAC filing (CHN), sanctions / export controls (RUS, BLR, IRN, PRK, CUB, SYR). */
export const BLOCKED_EVERYWHERE = list("CHN,RUS,BLR,IRN,PRK,CUB,SYR");

/** Not in OpenAI's supported list (on top of BLOCKED_EVERYWHERE). */
export const OPENAI_BLOCKED = new Set([...list("HKG,MAC"), ...list(process.env.OPENAI_BLOCKED_STOREFRONTS)]);

export function normalizeStorefront(raw) {
  const s = String(raw ?? "").trim().toUpperCase();
  return /^[A-Z]{3}$/.test(s) ? s : null;
}

/**
 * Whether `provider` ("openai" | "bedrock") may serve a user of `storefront`. An unknown storefront
 * (an older build, or StoreKit not answering yet) is allowed: the App Store listing already excludes
 * the blocked ones.
 */
export function providerAllowed(provider, storefront) {
  if (!storefront) return true;
  if (BLOCKED_EVERYWHERE.has(storefront)) return false;
  if (provider === "openai") return !OPENAI_BLOCKED.has(storefront);
  return true;
}

/** The models (and whether dish pictures) a storefront may use; the first allowed default leads. */
export function catalogFor(storefront) {
  const models = Object.entries(MODELS)
    .filter(([, m]) => providerAllowed(m.provider, storefront))
    .map(([id, m]) => ({ id, name: m.name, provider: m.provider }));
  const ids = models.map((m) => m.id);
  const def = ids.includes(DEFAULT_MODEL) ? DEFAULT_MODEL : ids.includes(FALLBACK_MODEL) ? FALLBACK_MODEL : ids[0] ?? null;
  return { default: def, images: providerAllowed("openai", storefront), models };
}
