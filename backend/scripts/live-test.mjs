// End to end against the deployed Lambda with a dev user (dev:*), minted from the session secret.
//   AWS_PROFILE=claude-agent node scripts/live-test.mjs <function-url>
// Costs about US$0.015 (one short menu call, one low-quality picture). Prints sizes and credits only.
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import { issueSessionToken } from "../src/auth.mjs";

const base = (process.argv[2] ?? "").replace(/\/$/, "");
if (!base) throw new Error("usage: live-test.mjs <function-url>");
const sm = new SecretsManagerClient({ region: "us-west-2" });
const { SecretString } = await sm.send(new GetSecretValueCommand({ SecretId: "dateseries/foreignmenu-session-key" }));
const { token } = issueSessionToken(`dev:live-${Date.now()}`, JSON.parse(SecretString).key, { days: 1 });
const auth = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
const credits = async () => (await (await fetch(`${base}/credits`, { headers: auth })).json()).totalCredits;

console.log("before first use:", await credits());
let t = Date.now();
const res = await fetch(`${base}/menu`, { method: "POST", headers: auth, body: JSON.stringify({
  model: "gpt-4.1", stream: true, temperature: 0.2,
  response_format: { type: "json_schema", json_schema: { name: "dish", strict: true, schema: {
    type: "object", additionalProperties: false, properties: { translated: { type: "string" } }, required: ["translated"] } } },
  messages: [{ role: "system", content: "Translate the menu line into Simplified Chinese." },
             { role: "user", content: [{ type: "text", text: "Cebiche clásico con leche de tigre" }] }],
}) });
const sse = await res.text();
const content = sse.split("\n").filter((l) => l.startsWith("data:") && !l.includes("[DONE]"))
  .map((l) => { try { return JSON.parse(l.slice(5)).choices?.[0]?.delta?.content ?? ""; } catch { return ""; } }).join("");
console.log("menu:", res.status, `${Date.now() - t} ms`, "json ok:", !!JSON.parse(content).translated, "credits event:", sse.includes("foreignmenu.credits"));
console.log("after menu:", await credits(), "(signup 300; a short call costs < 1)");

t = Date.now();
const img = await fetch(`${base}/image`, { method: "POST", headers: auth, body: JSON.stringify({ prompt: "A small bowl of Peruvian cebiche, top view, food photo" }) });
const body = await img.json();
console.log("image:", img.status, `${Date.now() - t} ms`, "jpeg bytes:", body.data?.[0]?.b64_json ? Buffer.from(body.data[0].b64_json, "base64").length : 0, "charged:", body.credits?.charged);
console.log("after image:", await credits());

const bad = await fetch(`${base}/menu`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
console.log("no token:", bad.status);
const usage = await (await fetch(`${base}/usage`, { headers: auth })).json();
console.log("usage today:", usage.days.at(-1));
const del = await fetch(`${base}/account`, { method: "DELETE", headers: auth });
console.log("delete test account:", del.status);
