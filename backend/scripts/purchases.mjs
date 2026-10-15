// Support / revenue tool for the purchase records (src/purchaseRecords.mjs). Run locally:
//
//   AWS_PROFILE=claude-agent AWS_REGION=us-west-2 node scripts/purchases.mjs user apple:000123.abc   one user's purchases
//   … node scripts/purchases.mjs summary [--since 2026-10-01]                                 revenue by currency / product / env
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { config } from "../src/config.mjs";
import { PurchaseRecords } from "../src/purchaseRecords.mjs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const [cmd, arg, ...rest] = process.argv.slice(2);
const flag = (f) => { const all = [arg, ...rest]; const i = all.indexOf(f); return i >= 0 ? all[i + 1] : undefined; };

if (cmd === "user" && arg) {
  for (const p of await new PurchaseRecords(ddb, config.purchasesTable).list(arg)) {
    console.log([p.at, p.status, p.productId, p.credits ?? "", p.price ?? "", p.currency ?? "", p.storefront ?? "", p.environment ?? "", p.reason ?? "", p.transactionId ?? ""].join("\t"));
  }
} else if (cmd === "summary") {
  const since = flag("--since") ?? "0000";
  const rows = [];
  let start;
  do {
    const r = await ddb.send(new ScanCommand({ TableName: config.purchasesTable, ExclusiveStartKey: start }));
    rows.push(...(r.Items ?? []).filter((p) => p.at >= since));
    start = r.LastEvaluatedKey;
  } while (start);
  const sums = new Map();
  for (const p of rows.filter((x) => x.status === "credited")) {
    const k = [p.environment, p.currency ?? "?", p.productId].join("\t");
    const s = sums.get(k) ?? { n: 0, price: 0, credits: 0 };
    sums.set(k, { n: s.n + 1, price: s.price + (p.price ?? 0), credits: s.credits + (p.credits ?? 0) });
  }
  console.log("environment\tcurrency\tproduct\tpurchases\tgross\tcredits");
  for (const [k, s] of [...sums].sort()) console.log(`${k}\t${s.n}\t${s.price.toFixed(2)}\t${s.credits}`);
  const rejected = rows.filter((x) => x.status === "rejected");
  console.log(`rejected: ${rejected.length}`, Object.fromEntries(Object.entries(Object.groupBy(rejected, (x) => x.reason)).map(([k, v]) => [k, v.length])));
} else {
  console.error("usage: purchases.mjs user <userId> | summary [--since YYYY-MM-DD]");
  process.exit(2);
}
