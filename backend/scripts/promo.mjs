// Admin tool for promotion codes (run locally with the claude-agent profile; not part of the Lambda).
//
//   AWS_PROFILE=claude-agent AWS_REGION=us-west-2 node scripts/promo.mjs create LoveGulu --credits 2000 --expires 2030-12-31
//   … node scripts/promo.mjs show LoveGulu          code, credits, expiry, redemptions so far
//   … node scripts/promo.mjs disable LoveGulu       stop further redemptions (keeps the history)
//   … node scripts/promo.mjs expires LoveGulu --expires 2026-11-30   move the last valid day
//
// --expires takes a date: the code works through the end of that day in the billing time zone.
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { config } from "../src/config.mjs";
import { normalizePromoCode } from "../src/credits.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const [cmd, name, ...rest] = process.argv.slice(2);
const flag = (f) => { const i = rest.indexOf(f); return i >= 0 ? rest[i + 1] : undefined; };
if (!cmd || !name) { console.error("usage: promo.mjs create|show|expires|disable <code> [--credits N] [--expires YYYY-MM-DD] [--max N]"); process.exit(2); }
const code = normalizePromoCode(name);
const Key = { code, sk: "#meta" };

/** End of `day` in the billing zone, as the first instant after it (UTC ISO). */
function endOfDay(day) {
  const probe = new Date(`${day}T12:00:00Z`);
  const tzName = new Intl.DateTimeFormat("en-US", { timeZone: config.billingTimeZone, timeZoneName: "longOffset" })
    .formatToParts(probe).find((p) => p.type === "timeZoneName").value; // e.g. "GMT-08:00"
  const offset = tzName.replace("GMT", "") || "+00:00";
  const next = new Date(new Date(`${day}T00:00:00${offset}`).getTime() + 86400000);
  return next.toISOString();
}

if (cmd === "create") {
  const credits = Number(flag("--credits"));
  const expires = flag("--expires");
  if (!Number.isInteger(credits) || credits <= 0 || !/^\d{4}-\d{2}-\d{2}$/.test(expires ?? "")) {
    console.error("create needs --credits <positive integer> and --expires YYYY-MM-DD"); process.exit(2);
  }
  const max = flag("--max") ? Number(flag("--max")) : undefined;
  await ddb.send(new PutCommand({
    TableName: config.promoTable,
    Item: { ...Key, displayName: name, credits, expiresAt: endOfDay(expires), active: true, redemptions: 0,
            ...(max ? { maxRedemptions: max } : {}), createdAt: new Date().toISOString() },
    ConditionExpression: "attribute_not_exists(code)",
  }));
  console.log(`created ${name}: ${credits} credits, valid until ${expires} (${config.billingTimeZone})`);
} else if (cmd === "show") {
  const { Item } = await ddb.send(new GetCommand({ TableName: config.promoTable, Key }));
  if (!Item) { console.log("no such code"); process.exit(1); }
  const { Count } = await ddb.send(new QueryCommand({ TableName: config.promoTable, KeyConditionExpression: "code = :c AND begins_with(sk, :u)",
    ExpressionAttributeValues: { ":c": code, ":u": "user#" }, Select: "COUNT" }));
  console.log({ ...Item, redemptionItems: Count });
} else if (cmd === "expires") {
  const expires = flag("--expires");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(expires ?? "")) { console.error("expires needs --expires YYYY-MM-DD"); process.exit(2); }
  await ddb.send(new UpdateCommand({ TableName: config.promoTable, Key, UpdateExpression: "SET expiresAt = :e",
    ConditionExpression: "attribute_exists(code)", ExpressionAttributeValues: { ":e": endOfDay(expires) } }));
  console.log(`${name} now valid until ${expires} (${config.billingTimeZone})`);
} else if (cmd === "disable") {
  await ddb.send(new UpdateCommand({ TableName: config.promoTable, Key, UpdateExpression: "SET active = :f",
    ConditionExpression: "attribute_exists(code)", ExpressionAttributeValues: { ":f": false } }));
  console.log(`disabled ${name}`);
} else {
  console.error(`unknown command ${cmd}`); process.exit(2);
}
