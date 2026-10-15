import assert from "node:assert/strict";
import { test } from "node:test";
import { catalogFor, normalizeStorefront, providerAllowed } from "../src/regions.mjs";
import { relayBedrockMenu, repair, toConverse } from "../src/bedrock.mjs";
import { menuRequest } from "../src/relay.mjs";

test("storefronts: OpenAI not in HK/Macau, nothing in China or sanctioned countries, unknown allowed", () => {
  assert.equal(normalizeStorefront(" hkg "), "HKG");
  assert.equal(normalizeStorefront("HK"), null);
  assert.equal(providerAllowed("openai", "USA"), true);
  assert.equal(providerAllowed("openai", "HKG"), false);
  for (const s of ["MAC", "VEN", "XKS", "AIA", "VGB", "MSR", "TCA"]) assert.equal(providerAllowed("openai", s), false);
  for (const s of ["JPN", "TWN", "VNM", "GBR", "AFG"]) assert.equal(providerAllowed("openai", s), true);
  assert.equal(providerAllowed("bedrock", "HKG"), true);
  for (const s of ["CHN", "RUS", "IRN", "PRK"]) assert.equal(providerAllowed("bedrock", s), false);
  assert.equal(providerAllowed("openai", null), true);
});

test("the catalog per storefront: Hong Kong gets Mistral and no pictures; China gets nothing", () => {
  assert.equal(catalogFor("USA").default, "gpt-4.1");
  assert.deepEqual(catalogFor("HKG"), { default: "mistral-large-3", images: false, models: [{ id: "mistral-large-3", name: "Mistral Large 3", provider: "bedrock" }] });
  assert.deepEqual(catalogFor("CHN"), { default: null, images: false, models: [] });
});

test("a menu request picks the region's default when the model is missing or unknown", () => {
  const raw = { messages: [{ role: "user", content: "x" }] };
  assert.equal(menuRequest(raw, { maxOutputTokens: 1, maxImages: 2, defaultModel: "mistral-large-3" }).model.id, "mistral-large-3");
  assert.equal(menuRequest({ ...raw, model: "gpt-4.1" }, { maxOutputTokens: 1, maxImages: 2, defaultModel: "mistral-large-3" }).model.provider, "openai");
});

const schema = { type: "object", additionalProperties: false, properties: {
  restaurantName: { type: ["string", "null"] },
  lines: { type: "array", items: { type: "object", properties: { index: { type: "integer" }, role: { type: "string", enum: ["dish_name", "other"] }, translated: { type: "string" } } } },
  dishes: { type: "array", items: { type: "object", properties: {
    originalName: { type: "string" }, nameLine: { type: "integer" }, price: { type: ["string", "null"] },
    tags: { type: "array", items: { type: "string", enum: ["vegan", "contains_seafood", "contains_chicken"] } },
    photoBBox: { anyOf: [{ type: "object", properties: { x: { type: "number" } } }, { type: "null" }] }, recommended: { type: "boolean" } } } } } };

test("repair: invented tags map onto the enum or go, missing fields get typed defaults, bad roles become other", () => {
  const fixed = repair({ lines: [{ index: "3", role: "headline", translated: "汤" }],
    dishes: [{ originalName: "Ceviche", tags: ["contains_seafood", "contains_gluten", "vegan"], extra: 1 }] }, schema);
  assert.deepEqual(fixed.lines, [{ index: 3, role: "other", translated: "汤" }]);
  assert.deepEqual(fixed.dishes[0], { originalName: "Ceviche", nameLine: -1, price: null, tags: ["contains_seafood", "vegan"], photoBBox: null, recommended: false });
  assert.equal(fixed.restaurantName, null);
});

test("a Bedrock answer streams back as Chat Completions SSE with usage, invented tags fixed", async () => {
  const body = { messages: [{ role: "system", content: "translate" },
    { role: "user", content: [{ type: "image_url", image_url: { url: "data:image/jpeg;base64,AAAA" } }, { type: "text", text: "0: Ceviche" }] }],
    response_format: { type: "json_schema", json_schema: { name: "menu_lines", schema } }, temperature: 0.2 };
  const conv = toConverse(body);
  assert.equal(conv.system[0].text, "translate");
  assert.equal(conv.messages[0].content[0].image.format, "jpeg");
  let sent;
  const send = async (cmd) => { sent = cmd.input; return { stopReason: "tool_use", usage: { inputTokens: 4000, outputTokens: 9000 },
    output: { message: { content: [{ toolUse: { name: "menu_lines", input: { lines: [], dishes: [{ originalName: "Ceviche", tags: ["contains_fish", "contains_shellfish"] }] } } }] } } }; };
  const chunks = [];
  const r = await relayBedrockMenu({ modelId: "mistral.x", body, maxOutputTokens: 16000, write: (c) => chunks.push(c), onStart: () => {}, send });
  assert.equal(sent.toolConfig.toolChoice.tool.name, "menu_lines");
  assert.equal(sent.inferenceConfig.temperature, 0.2);
  assert.deepEqual(r.usage, { input: 4000, output: 9000, cached: 0 });
  const sse = chunks.join("");
  assert.ok(sse.endsWith("data: [DONE]\n\n"));
  const content = sse.split("\n").filter((l) => l.startsWith("data: {")).map((l) => JSON.parse(l.slice(6)))
    .map((c) => c.choices[0]?.delta?.content ?? "").join("");
  assert.deepEqual(JSON.parse(content).dishes[0].tags, ["contains_seafood"]);
  assert.match(sse, /"usage":\{"prompt_tokens":4000,"completion_tokens":9000\}/);
});
