import assert from "node:assert/strict";
import { test } from "node:test";
import { ChatUsageSniffer, imageRequest, menuRequest, relayMenu, RequestError } from "../src/relay.mjs";
import { chatCostUsd, chatModel, imageCostUsd, tenthsForUsd } from "../src/pricing.mjs";

const limits = { maxOutputTokens: 32000, maxImages: 2 };
const page = (extra = {}) => ({
  model: "gpt-4.1",
  messages: [
    { role: "system", content: "You are a menu translation engine." },
    { role: "user", content: [
      { type: "image_url", image_url: { url: "data:image/jpeg;base64,AAAA", detail: "low" } },
      { type: "text", text: "OCR lines (index: text):\n0: Cebiche clásico" },
    ] },
  ],
  stream: true,
  response_format: { type: "json_schema", json_schema: { name: "menu_lines", strict: true, schema: { type: "object" } } },
  temperature: 0.2,
  ...extra,
});

test("a menu request keeps the app's messages and schema, and the server owns model, streaming and the cap", () => {
  const { body, model, inputTokens, images } = menuRequest(page({ max_completion_tokens: 999999, user: "x", tools: [] }), limits);
  assert.equal(model.id, "gpt-4.1");
  assert.equal(body.max_completion_tokens, 32000);
  assert.deepEqual(body.stream_options, { include_usage: true });
  assert.equal(body.temperature, 0.2);
  assert.equal(body.response_format.json_schema.name, "menu_lines");
  assert.equal(body.tools, undefined);
  assert.equal(body.user, undefined);
  assert.equal(images, 1);
  assert.ok(inputTokens > 85 && inputTokens < 200);
});

test("an unknown model falls back to the default; reasoning models get effort, not temperature", () => {
  assert.equal(menuRequest(page({ model: "gpt-9-ultra" }), limits).model.id, "gpt-4.1");
  const { body } = menuRequest(page({ model: "gpt-5-mini", reasoning_effort: "low" }), limits);
  assert.equal(body.reasoning_effort, "low");
  assert.equal(body.temperature, undefined);
});

test("malformed requests and too many photos are refused", () => {
  assert.throws(() => menuRequest({}, limits), RequestError);
  assert.throws(() => menuRequest({ messages: [{ role: "tool", content: "x" }] }, limits), RequestError);
  const many = page();
  many.messages[1].content.push(...Array(2).fill(many.messages[1].content[0]));
  assert.throws(() => menuRequest(many, limits), /at most 2/);
});

test("the usage chunk is found across split network chunks", () => {
  const s = new ChatUsageSniffer();
  const stream = [
    `data: {"choices":[{"delta":{"content":"{\\"lines\\""}}]}\n\n`,
    `data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n`,
    `data: {"choices":[],"usage":{"prompt_tokens":3000,"completion_tokens":5000,"prompt_tokens_details":{"cached_tokens":1000}}}\n\n`,
    "data: [DONE]\n\n",
  ].join("");
  for (let i = 0; i < stream.length; i += 7) s.push(stream.slice(i, i + 7));
  assert.deepEqual(s.usage, { input: 3000, output: 5000, cached: 1000 });
  assert.equal(s.finishReason, "stop");
});

test("relayMenu copies the bytes through and reports the usage", async () => {
  const sse = `data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}\n\ndata: [DONE]\n\n`;
  const fetchImpl = async () => new Response(sse, { status: 200 });
  const written = [];
  let started;
  const r = await relayMenu({ apiKey: "k", body: {}, write: (c) => written.push(Buffer.from(c).toString()), onStart: (s) => { started = s; }, fetchImpl });
  assert.equal(started, 200);
  assert.equal(written.join(""), sse);
  assert.deepEqual(r.usage, { input: 10, output: 2, cached: 0 });
});

test("an upstream error is reported without starting the stream", async () => {
  const fetchImpl = async () => new Response(JSON.stringify({ error: { message: "Rate limit" } }), { status: 429 });
  let started = false;
  const r = await relayMenu({ apiKey: "k", body: {}, write: () => {}, onStart: () => { started = true; }, fetchImpl });
  assert.equal(r.ok, false);
  assert.equal(r.status, 429);
  assert.equal(started, false);
});

test("image requests are pinned to one low-quality square jpeg", () => {
  const { body } = imageRequest({ prompt: "A bowl of cebiche", size: "4096x4096", quality: "high", n: 8, model: "dall-e-3" }, { maxPromptChars: 4000 });
  assert.deepEqual([body.model, body.size, body.quality, body.n, body.output_format], ["gpt-image-1-mini", "1024x1024", "low", 1, "jpeg"]);
  assert.throws(() => imageRequest({ prompt: "" }, { maxPromptChars: 4000 }), RequestError);
});

test("credits follow the dollar cost: US$0.005 a credit, charged to 0.1, at least 0.1", () => {
  assert.equal(tenthsForUsd(0.005, 0.005), 10);
  assert.equal(tenthsForUsd(0.0005, 0.005), 1);
  assert.equal(tenthsForUsd(0.0000001, 0.005), 1);
  // A typical page on gpt-4.1: 3k in (1k cached), 5k out ≈ US$0.0445 → 8.9 credits.
  const page = chatCostUsd(chatModel("gpt-4.1"), { input: 3000, cached: 1000, output: 5000 });
  assert.equal(tenthsForUsd(page, 0.005), 89);
  // A low-quality 2×2 collage on gpt-image-1-mini: ~170 prompt tokens + 272 output ≈ US$0.0025 → 0.5 credit.
  assert.equal(tenthsForUsd(imageCostUsd({ text: 170, output: 272 }), 0.005), 6);
});

test("an idle stream gets keep-alive comments, but only between events", async () => {
  const enc = new TextEncoder();
  const parts = ['data: {"choices":[{"delta":{"content":"he', 'llo"}}]}\n\n', 'data: [DONE]\n\n'];
  const pause = (ms) => new Promise((r) => setTimeout(r, ms));
  const body = new ReadableStream({ async start(c) {
    c.enqueue(enc.encode(parts[0])); await pause(60);   // idle INSIDE an event: no keep-alive allowed
    c.enqueue(enc.encode(parts[1])); await pause(60);   // idle between events: keep-alive expected
    c.enqueue(enc.encode(parts[2])); c.close();
  } });
  const out = [];
  await relayMenu({ apiKey: "k", body: {}, write: (x) => out.push(typeof x === "string" ? x : Buffer.from(x).toString()),
    onStart: () => {}, fetchImpl: async () => new Response(body, { status: 200 }), keepAliveMs: 20 });
  const sse = out.join("");
  assert.ok(sse.includes(': working\n\ndata: [DONE]'), "a keep-alive between the events");
  assert.ok(!sse.slice(0, sse.indexOf('llo"}}]}')).includes(": working"), "none inside the first event");
  assert.equal(sse.replace(/: working\n\n/g, ""), parts.join(""));
});
