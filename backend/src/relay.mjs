// The two OpenAI calls the app makes, relayed with our key. Request and response keep OpenAI's own
// shape, so the app's parsing doesn't change; the server picks the model and caps the output.
//   menu   Chat Completions, streamed: bytes are copied through while the final usage chunk is sniffed
//   image  Images (gpt-image-1-mini): one JSON response, passed through

import { chatModel, estimateTokens, tokensForImage } from "./pricing.mjs";
import { IMAGE_MODEL } from "./pricing.mjs";

export class RequestError extends Error {}

/**
 * Builds the upstream Chat Completions body from what the app sent. Only known fields pass;
 * stream + usage are forced on. Returns { body, model, inputTokens, images }.
 */
export function menuRequest(raw, { maxOutputTokens, maxImages, defaultModel }) {
  if (!raw || !Array.isArray(raw.messages) || raw.messages.length === 0 || raw.messages.length > 20) {
    throw new RequestError("messages must be a non-empty array");
  }
  const model = chatModel(raw.model, defaultModel);
  let text = "";
  let images = 0;
  let imageTokens = 0;
  for (const m of raw.messages) {
    if (!m || typeof m !== "object" || !["system", "developer", "user", "assistant"].includes(m.role)) {
      throw new RequestError("bad message");
    }
    if (typeof m.content === "string") { text += m.content; continue; }
    if (!Array.isArray(m.content)) throw new RequestError("bad message content");
    for (const part of m.content) {
      if (part?.type === "text" && typeof part.text === "string") text += part.text;
      else if (part?.type === "image_url" && typeof part.image_url?.url === "string") {
        images += 1;
        imageTokens += tokensForImage(part.image_url.detail);
      } else throw new RequestError("bad content part");
    }
  }
  if (images > maxImages) throw new RequestError(`at most ${maxImages} images per request`);
  const body = {
    model: model.id,
    messages: raw.messages,
    stream: true,
    stream_options: { include_usage: true },
    max_completion_tokens: maxOutputTokens,
  };
  if (raw.response_format !== undefined) body.response_format = raw.response_format;
  if (model.reasoning) {
    if (["minimal", "low", "medium", "high"].includes(raw.reasoning_effort)) body.reasoning_effort = raw.reasoning_effort;
  } else if (typeof raw.temperature === "number") {
    body.temperature = Math.min(Math.max(raw.temperature, 0), 2);
  }
  return { body, model, inputTokens: estimateTokens(text) + imageTokens, images, textChars: text.length };
}

/** Incrementally parses Chat Completions SSE and keeps the usage from the last chunk. */
export class ChatUsageSniffer {
  constructor() {
    this.buffer = "";
    this.usage = null;
    this.finishReason = null;
  }

  push(text) {
    this.buffer += text;
    let cut;
    while ((cut = this.buffer.indexOf("\n")) !== -1) {
      const line = this.buffer.slice(0, cut).trim();
      this.buffer = this.buffer.slice(cut + 1);
      if (!line.startsWith("data:")) continue;
      const data = line.slice(5).trim();
      if (!data || data === "[DONE]") continue;
      try {
        const chunk = JSON.parse(data);
        const reason = chunk.choices?.[0]?.finish_reason;
        if (reason) this.finishReason = reason;
        if (chunk.usage) {
          const u = chunk.usage;
          this.usage = { input: u.prompt_tokens ?? 0, output: u.completion_tokens ?? 0, cached: u.prompt_tokens_details?.cached_tokens ?? 0 };
        }
      } catch {
        // keep-alives and partial garbage: ignore
      }
    }
  }
}

/**
 * Calls Chat Completions and copies every byte to `write`. `onStart(status)` runs once the upstream
 * answered. Returns { ok, status, usage, finishReason, errorBody? }.
 */
export async function relayMenu({ apiKey, body, write, onStart, fetchImpl = fetch }) {
  const upstream = await fetchImpl("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!upstream.ok || !upstream.body) {
    return { ok: false, status: upstream.status, usage: null, errorBody: await upstream.text() };
  }
  onStart(upstream.status);
  const sniffer = new ChatUsageSniffer();
  const decoder = new TextDecoder();
  // Keep reading even if the app has gone away: the usage arrives at the very end.
  for await (const chunk of upstream.body) {
    sniffer.push(decoder.decode(chunk, { stream: true }));
    write(chunk);
  }
  return { ok: true, status: upstream.status, usage: sniffer.usage, finishReason: sniffer.finishReason };
}

/** The upstream Images body: our model, one low-quality square picture. */
export function imageRequest(raw, { maxPromptChars }) {
  const prompt = raw?.prompt;
  if (typeof prompt !== "string" || !prompt.trim() || prompt.length > maxPromptChars) {
    throw new RequestError(`prompt must be 1–${maxPromptChars} characters`);
  }
  return {
    body: { model: IMAGE_MODEL.id, prompt, size: "1024x1024", quality: "low", n: 1, output_format: "jpeg", output_compression: 85 },
    promptTokens: estimateTokens(prompt),
  };
}

/** Calls Images. Returns { ok, status, json?, usage?, errorBody? }. */
export async function generateImage({ apiKey, body, fetchImpl = fetch }) {
  const upstream = await fetchImpl("https://api.openai.com/v1/images/generations", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await upstream.text();
  if (!upstream.ok) return { ok: false, status: upstream.status, errorBody: text };
  const json = JSON.parse(text);
  const u = json.usage ?? {};
  const usage = {
    text: u.input_tokens_details?.text_tokens ?? u.input_tokens ?? 0,
    image: u.input_tokens_details?.image_tokens ?? 0,
    output: u.output_tokens ?? 0,
  };
  return { ok: true, status: upstream.status, json, usage: json.usage ? usage : null };
}

/** OpenAI's error message only (never the request). */
export function upstreamMessage(text) {
  try { return JSON.parse(text).error?.message ?? "upstream error"; } catch { return "upstream error"; }
}
