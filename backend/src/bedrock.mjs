// Menu requests answered by a Bedrock model (where OpenAI doesn't serve the user, or when picked).
// The app sends and parses OpenAI Chat Completions, so this translates both ways:
//   request   messages + response_format.json_schema → Converse with the schema as a forced tool
//   response  the tool's JSON, repaired against the schema, streamed back as Chat Completions SSE
//             chunks, a usage chunk and [DONE] — byte-compatible with what relayMenu passes through.
// Converse is called without streaming so the JSON can be repaired whole; keep-alive comments go out
// while the model works (a page takes ~40 s).

import { BedrockRuntimeClient, ConverseCommand } from "@aws-sdk/client-bedrock-runtime";

const client = new BedrockRuntimeClient({});

/** Diet tags the models invent, mapped onto the app's enum (unmapped ones are dropped). */
const ENUM_SYNONYMS = {
  contains_fish: "contains_seafood", contains_shellfish: "contains_seafood", contains_shrimp: "contains_seafood",
  contains_crab: "contains_seafood", contains_mollusc: "contains_seafood", contains_molluscs: "contains_seafood",
  seafood: "contains_seafood", fish: "contains_seafood", pork: "contains_pork", chicken: "contains_chicken",
  poultry: "contains_chicken", beef: "contains_beef", lamb: "contains_lamb", mutton: "contains_lamb",
  vegetarian_option: "vegetarian", vegan_option: "vegan", "gluten-free": "gluten_free", gf: "gluten_free",
};

/** A value of the schema's type when the model left a required field out. */
function emptyFor(schema) {
  const types = [].concat(schema?.type ?? []);
  if (schema?.anyOf) return null;
  if (types.includes("null")) return null;
  if (types.includes("array")) return [];
  if (types.includes("integer") || types.includes("number")) return -1;
  if (types.includes("boolean")) return false;
  if (types.includes("object")) return repair({}, schema);
  return "";
}

/**
 * Makes `value` fit `schema` the way the app's strict decoder needs: required keys present, unknown keys
 * dropped, enum strings mapped or replaced ("other" when the enum has it), enum arrays mapped and
 * deduplicated, numbers that came back as strings converted.
 */
export function repair(value, schema) {
  if (!schema) return value;
  if (schema.anyOf) {
    if (value === null || value === undefined) return null;
    const objectSchema = schema.anyOf.find((s) => s.type === "object");
    return objectSchema && typeof value === "object" ? repair(value, objectSchema) : value;
  }
  const types = [].concat(schema.type ?? []);
  if (value === null && types.includes("null")) return null;
  if (types.includes("object")) {
    const v = value && typeof value === "object" && !Array.isArray(value) ? value : {};
    const out = {};
    for (const [key, sub] of Object.entries(schema.properties ?? {})) {
      out[key] = key in v ? repair(v[key], sub) : emptyFor(sub);
    }
    return out;
  }
  if (types.includes("array")) {
    if (!Array.isArray(value)) return [];
    const items = value.map((x) => repair(x, schema.items));
    if (schema.items?.enum) return [...new Set(items.filter((x) => schema.items.enum.includes(x)))];
    return items;
  }
  if (schema.enum) {
    const s = String(value ?? "");
    if (schema.enum.includes(s)) return s;
    const mapped = ENUM_SYNONYMS[s.toLowerCase()];
    if (mapped && schema.enum.includes(mapped)) return mapped;
    return schema.enum.includes("other") ? "other" : null;
  }
  if (types.includes("integer")) {
    const n = Math.trunc(Number(value));
    return Number.isFinite(n) ? n : -1;
  }
  if (types.includes("number")) {
    const n = Number(value);
    return Number.isFinite(n) ? n : 0;
  }
  if (types.includes("boolean")) return value === true || value === "true";
  if (types.includes("string")) return value === null || value === undefined ? (types.includes("null") ? null : "") : String(value);
  return value;
}


/** Chat Completions messages → Converse system + messages. Images arrive as data: URLs. */
export function toConverse(body) {
  const system = [];
  const messages = [];
  for (const m of body.messages) {
    const parts = typeof m.content === "string" ? [{ type: "text", text: m.content }] : m.content;
    if (m.role === "system" || m.role === "developer") {
      for (const p of parts) if (p.type === "text") system.push({ text: p.text });
      continue;
    }
    const content = [];
    for (const p of parts) {
      if (p.type === "text") content.push({ text: p.text });
      else if (p.type === "image_url") {
        const match = /^data:image\/(jpeg|jpg|png|webp|gif);base64,(.+)$/s.exec(p.image_url.url);
        if (match) content.push({ image: { format: match[1] === "jpg" ? "jpeg" : match[1], source: { bytes: Buffer.from(match[2], "base64") } } });
      }
    }
    messages.push({ role: m.role === "assistant" ? "assistant" : "user", content });
  }
  const schema = body.response_format?.json_schema?.schema;
  return { system, messages, schema };
}

/** Normalises enum-array synonyms inside the raw model JSON before repair (repair drops unknowns). */
function mapSynonyms(value) {
  if (Array.isArray(value)) return value.map(mapSynonyms);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, mapSynonyms(v)]));
  if (typeof value === "string" && ENUM_SYNONYMS[value.toLowerCase()]) return ENUM_SYNONYMS[value.toLowerCase()];
  return value;
}

/**
 * Answers a menu request with a Bedrock model and writes Chat Completions SSE to `write`.
 * Returns { ok, status, usage, finishReason, errorBody? } like relayMenu.
 */
export async function relayBedrockMenu({ modelId, body, maxOutputTokens, write, onStart, send = (c) => client.send(c) }) {
  const { system, messages, schema } = toConverse(body);
  const input = { modelId, system, messages, inferenceConfig: { maxTokens: maxOutputTokens } };
  if (typeof body.temperature === "number") input.inferenceConfig.temperature = body.temperature;
  if (schema) {
    input.toolConfig = {
      tools: [{ toolSpec: { name: "menu_lines", description: "Return the classified, translated menu.", inputSchema: { json: schema } } }],
      toolChoice: { tool: { name: "menu_lines" } },
    };
  }
  let started = false;
  const keepAlive = setInterval(() => {
    if (!started) { started = true; onStart(200); }
    write(": working\n\n"); // an SSE comment: ignored by the app, keeps the connection busy
  }, 10_000);
  let r;
  try {
    r = await send(new ConverseCommand(input));
  } catch (e) {
    clearInterval(keepAlive);
    if (started) throw e; // mid-stream: the caller ends the stream with an error and refunds
    const status = e?.$metadata?.httpStatusCode ?? 502;
    return { ok: false, status: status === 429 ? 429 : 502, usage: null, errorBody: JSON.stringify({ error: { message: e?.name ?? "bedrock error" } }) };
  }
  clearInterval(keepAlive);
  if (!started) onStart(200);
  const parts = r.output?.message?.content ?? [];
  const tool = parts.find((p) => p.toolUse);
  let text;
  if (schema) {
    let raw = tool?.toolUse?.input;
    if (!raw) { // a model that answered in text after all: take the JSON object out of it
      const t = parts.map((p) => p.text ?? "").join("");
      try { raw = JSON.parse(t.slice(t.indexOf("{"), t.lastIndexOf("}") + 1)); } catch { raw = {}; }
    }
    text = JSON.stringify(repair(mapSynonyms(raw), schema));
  } else {
    text = parts.map((p) => p.text ?? "").join("");
  }
  const id = `bedrock-${Date.now()}`;
  const chunk = (delta, finish = null) => `data: ${JSON.stringify({ id, object: "chat.completion.chunk", model: modelId,
    choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
  write(chunk({ role: "assistant", content: "" }));
  for (let i = 0; i < text.length; i += 2000) write(chunk({ content: text.slice(i, i + 2000) }));
  const finishReason = r.stopReason === "max_tokens" ? "length" : "stop";
  write(chunk({}, finishReason));
  const usage = { prompt_tokens: r.usage?.inputTokens ?? 0, completion_tokens: r.usage?.outputTokens ?? 0 };
  write(`data: ${JSON.stringify({ id, object: "chat.completion.chunk", model: modelId, choices: [], usage })}\n\n`);
  write("data: [DONE]\n\n");
  return { ok: true, status: 200, usage: { input: usage.prompt_tokens, output: usage.completion_tokens, cached: 0 }, finishReason };
}
