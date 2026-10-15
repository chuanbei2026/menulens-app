// OpenAI list prices (US$ per 1M tokens) and what a request costs in tenths of a credit.
// Credits are priced by cost, so every model costs the user the same per dollar we pay.

import { config } from "./config.mjs";
import { TENTHS_PER_CREDIT } from "./credits.mjs";

/** Chat models the app may ask for (设置 → 模型). `reasoning`: takes reasoning_effort, not temperature. */
export const MODELS = {
  "gpt-4.1": { input: 2.0, cached: 0.5, output: 8.0 },
  "gpt-4o": { input: 2.5, cached: 1.25, output: 10.0 },
  "gpt-5": { input: 1.25, cached: 0.125, output: 10.0, reasoning: true },
  "gpt-5-mini": { input: 0.25, cached: 0.025, output: 2.0, reasoning: true },
};

/** gpt-image-1: text and image input, image output. */
export const IMAGE_MODEL = { id: "gpt-image-1", text: 5.0, image: 10.0, output: 40.0 };

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

export function chatModel(requested) {
  const id = MODELS[requested] ? requested : config.defaultModel;
  return { id, ...MODELS[id] };
}

/** Tenths of a credit for `usd`, rounded up, at least 0.1 credit. */
export function tenthsForUsd(usd, usdPerCredit = config.usdPerCredit) {
  // The epsilon absorbs float noise (0.0005 / 0.0005 must stay 1, not 2).
  return Math.max(1, Math.ceil((usd * TENTHS_PER_CREDIT) / usdPerCredit - 1e-9));
}

/** US$ for a chat completion's usage { input, cached, output }. */
export function chatCostUsd(model, { input = 0, cached = 0, output = 0 }) {
  return ((input - cached) * model.input + cached * model.cached + output * model.output) / 1e6;
}

/** US$ for an image generation's usage { text, image, output } (token counts). */
export function imageCostUsd({ text = 0, image = 0, output = 0 }) {
  return (text * IMAGE_MODEL.text + image * IMAGE_MODEL.image + output * IMAGE_MODEL.output) / 1e6;
}
