// Benchmarks models on the app's real menu task (MenuLens/Sources/Services/OpenAIClient.swift prompt
// and schema) against the bundled sample scans, whose shipped gpt-4.1 Chinese results are the reference.
//
//   OPENAI_API_KEY=… AWS_PROFILE=claude-agent node scripts/bench-menu.mjs <outdir> [model…]
//
// Models: "openai:gpt-4.1" (direct), Bedrock ids ("us.meta.llama4-maverick-17b-instruct-v1:0"), or
// "backend:<STOREFRONT>:<model>" through the deployed Lambda (session token in $FM_TOKEN), e.g.
// "backend:HKG:mistral-large-3".
// Bedrock models get the schema as a forced tool (Converse toolChoice), falling back to plain JSON.
// Prints per page: JSON ok, lines returned, role agreement, dishes found, latency, tokens; writes raw
// outputs to <outdir>. Never logs secrets.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { BedrockRuntimeClient, ConverseCommand } from "@aws-sdk/client-bedrock-runtime";

const root = new URL("../../", import.meta.url).pathname;
const out = process.argv[2];
const models = process.argv.slice(3);
mkdirSync(out, { recursive: true });

// --- The app's prompt and schema --------------------------------------------------------------
const swift = readFileSync(`${root}MenuLens/Sources/Services/OpenAIClient.swift`, "utf8");
const raw = swift.match(/private var systemPrompt: String \{\s*"""\n([\s\S]*?)\n\s*"""/)[1];
const target = "Simplified Chinese";
const systemPrompt = raw.split("\n").map((l) => l.replace(/^ {8}/, "")).join("\n")
  .replace(/\\\n/g, "").replace(/\\\(targetLanguage\)/g, target);
const rect = { type: "object", additionalProperties: false, properties: { x: { type: "number" }, y: { type: "number" }, width: { type: "number" }, height: { type: "number" } }, required: ["x", "y", "width", "height"] };
const line = { type: "object", additionalProperties: false, properties: { index: { type: "integer" }, role: { type: "string", enum: ["section_title", "dish_name", "description", "price", "other"] }, translated: { type: "string" } }, required: ["index", "role", "translated"] };
const tags = ["vegan", "vegetarian", "gluten_free", "contains_pork", "contains_chicken", "contains_beef", "contains_lamb", "contains_seafood"];
const dish = { type: "object", additionalProperties: false, properties: {
  originalName: { type: "string" }, translatedName: { type: "string" }, nameLine: { type: "integer" },
  descriptionLines: { type: "array", items: { type: "integer" } }, translatedDescription: { type: "string" },
  price: { type: ["string", "null"] }, sectionOriginal: { type: ["string", "null"] }, sectionTranslated: { type: ["string", "null"] },
  sectionTitleLine: { type: "integer" }, tags: { type: "array", items: { type: "string", enum: tags } },
  photoBBox: { anyOf: [rect, { type: "null" }] }, recommended: { type: "boolean" }, recommendReason: { type: "string" } },
  required: ["originalName", "translatedName", "nameLine", "descriptionLines", "translatedDescription", "price", "sectionOriginal", "sectionTranslated", "sectionTitleLine", "tags", "photoBBox", "recommended", "recommendReason"] };
const schema = { type: "object", additionalProperties: false, properties: {
  sourceLanguage: { type: "string" }, sourceLanguageName: { type: "string" }, restaurantName: { type: ["string", "null"] },
  lines: { type: "array", items: line }, dishes: { type: "array", items: dish } },
  required: ["sourceLanguage", "sourceLanguageName", "restaurantName", "lines", "dishes"] };

// --- Inputs: photo (1024 px), OCR inventory, reference ------------------------------------------
const samples = ["la-mar", "naan-n-curry"].map((name) => {
  const dir = `${root}MenuLens/Resources/Samples/en/${name}`;
  const scan = JSON.parse(readFileSync(`${dir}/scan.json`, "utf8"));
  const ref = JSON.parse(readFileSync(`${root}MenuLens/Resources/Samples/zh-Hans/${name}/scan.json`, "utf8")).pages[0];
  const jpg = `${out}/${name}-1024.jpg`;
  execFileSync("sips", ["-Z", "1024", `${dir}/page_0.jpg`, "--out", jpg], { stdio: "ignore" });
  const lines = scan.pages[0].textLines.map((l) => l.original);
  return { name, jpeg: readFileSync(jpg), lines, ref };
});

// --- Callers ----------------------------------------------------------------------------------
const bedrock = new BedrockRuntimeClient({ region: "us-west-2" });
async function callOpenAI(model, s) {
  const r = await fetch("https://api.openai.com/v1/chat/completions", { method: "POST",
    headers: { Authorization: `Bearer ${process.env.OPENAI_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model, temperature: 0.2, response_format: { type: "json_schema", json_schema: { name: "menu_lines", strict: true, schema } },
      messages: [{ role: "system", content: systemPrompt }, { role: "user", content: [
        { type: "image_url", image_url: { url: `data:image/jpeg;base64,${s.jpeg.toString("base64")}`, detail: "low" } },
        { type: "text", text: "OCR lines (index: text):\n" + s.lines.map((t, i) => `${i}: ${t}`).join("\n") }] }] }) });
  const j = await r.json();
  if (!r.ok) throw new Error(j.error?.message ?? r.status);
  return { text: j.choices[0].message.content, input: j.usage.prompt_tokens, output: j.usage.completion_tokens };
}
async function callBackend(spec, s) {
  const [, storefront, model] = spec.split(":");
  const base = "https://uwondrk7ngmf3jgkimsifwa62q0fwgzo.lambda-url.us-west-2.on.aws";
  const r = await fetch(`${base}/menu`, { method: "POST",
    headers: { Authorization: `Bearer ${process.env.FM_TOKEN}`, "Content-Type": "application/json", "X-Storefront": storefront },
    body: JSON.stringify({ model, stream: true, temperature: 0.2,
      response_format: { type: "json_schema", json_schema: { name: "menu_lines", strict: true, schema } },
      messages: [{ role: "system", content: systemPrompt }, { role: "user", content: [
        { type: "image_url", image_url: { url: `data:image/jpeg;base64,${s.jpeg.toString("base64")}`, detail: "low" } },
        { type: "text", text: "OCR lines (index: text):\n" + s.lines.map((t, i) => `${i}: ${t}`).join("\n") }] }] }) });
  const sse = await r.text();
  if (!r.ok) throw new Error(`${r.status} ${sse.slice(0, 200)}`);
  let text = "", usage = {}, credits = null;
  for (const l of sse.split("\n")) {
    if (!l.startsWith("data: {")) continue;
    const c = JSON.parse(l.slice(6));
    text += c.choices?.[0]?.delta?.content ?? "";
    if (c.usage) usage = c.usage;
    if ("charged" in c) credits = c.charged;
  }
  return { text, input: usage.prompt_tokens, output: usage.completion_tokens, stop: `charged ${credits}` };
}
async function callBedrock(modelId, s, useTool) {
  const user = { role: "user", content: [
    { image: { format: "jpeg", source: { bytes: s.jpeg } } },
    { text: "OCR lines (index: text):\n" + s.lines.map((t, i) => `${i}: ${t}`).join("\n")
      + (useTool ? "" : `\n\nRespond with ONLY a JSON object matching this JSON Schema, no prose, no code fences:\n${JSON.stringify(schema)}`) }] };
  const input = { modelId, system: [{ text: systemPrompt }], messages: [user], inferenceConfig: { maxTokens: 16000, temperature: 0.2 } };
  if (useTool) input.toolConfig = { tools: [{ toolSpec: { name: "menu_lines", description: "Return the classified, translated menu.", inputSchema: { json: schema } } }],
    toolChoice: { tool: { name: "menu_lines" } } };
  let r;
  try { r = await bedrock.send(new ConverseCommand(input)); }
  catch (e) {
    const cap = String(e.message).match(/model limit of (\d+)/);
    if (cap) input.inferenceConfig.maxTokens = Number(cap[1]); // e.g. Llama 4: 8192
    else if (/temperature/.test(String(e.message))) delete input.inferenceConfig.temperature; // e.g. Kimi K3
    else throw e;
    r = await bedrock.send(new ConverseCommand(input));
  }
  const parts = r.output.message.content;
  const tool = parts.find((p) => p.toolUse);
  const text = tool ? JSON.stringify(tool.toolUse.input) : parts.map((p) => p.text ?? "").join("");
  return { text, input: r.usage.inputTokens, output: r.usage.outputTokens, stop: r.stopReason };
}

// --- Scoring vs the shipped gpt-4.1 result ------------------------------------------------------
function parse(text) {
  const t = text.trim().replace(/^```(json)?/, "").replace(/```$/, "");
  return JSON.parse(t.slice(t.indexOf("{"), t.lastIndexOf("}") + 1));
}
function score(s, doc) {
  const refRoles = s.ref.textLines.map((l) => l.role);
  const got = new Map((doc.lines ?? []).map((l) => [l.index, l]));
  let agree = 0;
  refRoles.forEach((role, i) => { if (got.get(i)?.role === role) agree++; });
  const refDishes = s.ref.sections.flatMap((x) => x.items);
  const norm = (n) => String(n ?? "").toLowerCase().replace(/[^a-zÀ-ɏ]/g, "");
  const names = new Set((doc.dishes ?? []).map((d) => norm(d.originalName)));
  const matched = refDishes.filter((d) => names.has(norm(d.originalName))).length;
  const zh = (doc.dishes ?? []).filter((d) => /[一-鿿]/.test(d.translatedName ?? "")).length;
  return { lines: `${got.size}/${refRoles.length}`, roleAgree: `${Math.round((100 * agree) / refRoles.length)}%`,
           dishes: `${(doc.dishes ?? []).length} (ref ${refDishes.length}, matched ${matched})`, zhNames: zh,
           recommended: (doc.dishes ?? []).filter((d) => d.recommended).length };
}

for (const model of models) {
  for (const s of samples) {
    const t = Date.now();
    let r, doc, err, mode = "tool";
    try {
      if (model.startsWith("openai:")) { mode = "schema"; r = await callOpenAI(model.slice(7), s); }
      else if (model.startsWith("backend:")) { mode = "backend"; r = await callBackend(model, s); }
      else {
        try { r = await callBedrock(model, s, true); }
        catch (e) { if (!/tool|Tool|support/.test(String(e.message))) throw e; mode = "json"; r = await callBedrock(model, s, false); }
      }
      writeFileSync(`${out}/${model.replace(/[:/]/g, "_")}-${s.name}.json`, r.text);
      doc = parse(r.text);
    } catch (e) { err = String(e.message ?? e).slice(0, 160); }
    const ms = Date.now() - t;
    console.log(JSON.stringify({ model, page: s.name, mode, ms, in: r?.input, out: r?.output, stop: r?.stop,
      ...(doc ? score(s, doc) : { error: err ?? "unparseable" }) }));
  }
}
