// OpenAI list prices (US$ per 1M tokens) and what a request costs in tenths of a credit.
// Credits are priced by cost, so every model costs the user the same per dollar we pay.

import { config } from "./config.mjs";
import { TENTHS_PER_CREDIT } from "./credits.mjs";

/**
 * Chat models the app may offer (设置 → 模型), with list prices (US$ per 1M tokens). `reasoning`: takes
 * reasoning_effort, not temperature. Bedrock models answer where OpenAI may not (regions.mjs); their
 * output is repaired against the schema before it reaches the app (bedrock.mjs).
 *
 * Measured 2026-10-15 on the two bundled sample menus (scripts/bench-menu.mjs, vs the shipped gpt-4.1
 * results): Mistral Large 3 got every line and 29/31 + 25/25 dishes in ~43 s at a third of gpt-4.1's
 * price, but invents diet tags (repaired) and writes weaker recommendation reasons. Llama 4 Maverick and
 * Kimi K3 broke the JSON, Gemma 3 skipped the lines, Pixtral Large was 110 s and missed dishes.
 */
export const MODELS = {
  "gpt-4.1": { provider: "openai", name: "GPT-4.1", input: 2.0, cached: 0.5, output: 8.0 },
  "gpt-5-mini": { provider: "openai", name: "GPT-5 mini", input: 0.25, cached: 0.025, output: 2.0, reasoning: true },
  "gpt-5": { provider: "openai", name: "GPT-5", input: 1.25, cached: 0.125, output: 10.0, reasoning: true },
  "gpt-4o": { provider: "openai", name: "GPT-4o", input: 2.5, cached: 1.25, output: 10.0 },
  "mistral-large-3": { provider: "bedrock", name: "Mistral Large 3", upstream: "mistral.mistral-large-3-675b-instruct",
                       input: 0.5, output: 1.5 },
};

/** The default where OpenAI serves the user, and where it doesn't. */
export const DEFAULT_MODEL = "gpt-4.1";
export const FALLBACK_MODEL = "mistral-large-3";

/** Dish pictures: text and image input, image output. gpt-image-1-mini is a fifth of gpt-image-1's price
 * (US$40 → 8 per 1M output tokens; same 272 tokens for a low-quality 1024² picture) and draws a 2×2
 * collage about as well (2026-10-15 side by side). */
export const IMAGE_MODEL = { id: "gpt-image-1-mini", text: 2.0, image: 2.5, output: 8.0 };

/** A low-quality 1024×1024 picture is 272 output tokens; reserve a little more. */
export const EXPECTED_IMAGE_OUTPUT_TOKENS = 400;

/** Upper-bound token estimate for text: UTF-8 bytes / 2 over-estimates every script we see. */
export function estimateTokens(text) {
  return Math.ceil(Buffer.byteLength(String(text ?? ""), "utf8") / 2) + 50;
}

/** A photo attached at "low" detail is 85 tokens; "high"/"auto" up to ~1600 for our ≤2000 px uploads. */
export function tokensForImage(detail) {
  return detail === "low" ? 85 : 1600;
}

export function chatModel(requested, fallback = config.defaultModel) {
  const id = MODELS[requested] ? requested : MODELS[fallback] ? fallback : DEFAULT_MODEL;
  return { id, ...MODELS[id] };
}

/** Tenths of a credit for `usd`, rounded up, at least 0.1 credit. */
export function tenthsForUsd(usd, usdPerCredit = config.usdPerCredit) {
  // The epsilon absorbs float noise (0.0005 / 0.0005 must stay 1, not 2).
  return Math.max(1, Math.ceil((usd * TENTHS_PER_CREDIT) / usdPerCredit - 1e-9));
}

/** US$ for a chat completion's usage { input, cached, output }. */
export function chatCostUsd(model, { input = 0, cached = 0, output = 0 }) {
  return ((input - cached) * model.input + cached * (model.cached ?? model.input) + output * model.output) / 1e6;
}

/** US$ for an image generation's usage { text, image, output } (token counts). */
export function imageCostUsd({ text = 0, image = 0, output = 0 }) {
  return (text * IMAGE_MODEL.text + image * IMAGE_MODEL.image + output * IMAGE_MODEL.output) / 1e6;
}
