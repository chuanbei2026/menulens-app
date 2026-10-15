// A tiny in-memory stand-in for the DynamoDB document client, enough for CreditStore's commands:
// Get / Put / Update / Delete / Query / TransactWrite with the expression subset credits.mjs uses
// (SET with + / - / if_not_exists, ADD, REMOVE; conditions with AND / OR / NOT, comparisons,
// attribute_exists / attribute_not_exists). Tests only: no indexes, no pagination.

class ConditionalCheckFailed extends Error {
  constructor() {
    super("The conditional request failed");
    this.name = "ConditionalCheckFailedException";
  }
}

function tokenize(src) {
  const re = /\s*(<>|<=|>=|[()=<>,+\-]|[#:]?[A-Za-z_][A-Za-z0-9_]*)/y;
  const out = [];
  let m;
  while (re.lastIndex < src.length && (m = re.exec(src))) out.push(m[1]);
  if (re.lastIndex < src.trimEnd().length) throw new Error(`fakeddb: can't parse ${src}`);
  return out;
}

/** Evaluates expressions against one item; `names` / `values` are the Expression maps. */
class Expr {
  constructor(src, item, names = {}, values = {}) {
    Object.assign(this, { t: tokenize(src), i: 0, item, names, values });
  }
  peek() { return this.t[this.i]; }
  next() { return this.t[this.i++]; }
  expect(tok) { if (this.next() !== tok) throw new Error(`fakeddb: expected ${tok}`); }
  name(tok) { return tok.startsWith("#") ? this.names[tok] : tok; }

  // Conditions
  or() { let v = this.and(); while (this.peek() === "OR") { this.next(); const r = this.and(); v = v || r; } return v; }
  and() { let v = this.not(); while (this.peek() === "AND") { this.next(); const r = this.not(); v = v && r; } return v; }
  not() { if (this.peek() === "NOT") { this.next(); return !this.not(); } return this.comparison(); }
  comparison() {
    if (this.peek() === "(") { this.next(); const v = this.or(); this.expect(")"); return v; }
    const fn = this.peek();
    if (fn === "attribute_exists" || fn === "attribute_not_exists") {
      this.next(); this.expect("("); const n = this.name(this.next()); this.expect(")");
      return (this.item?.[n] !== undefined) === (fn === "attribute_exists");
    }
    const a = this.operand(), op = this.next(), b = this.operand();
    if (a === undefined || b === undefined) return false;
    switch (op) {
      case "=": return a === b;
      case "<>": return a !== b;
      case "<": return a < b;
      case "<=": return a <= b;
      case ">": return a > b;
      case ">=": return a >= b;
      default: throw new Error(`fakeddb: operator ${op}`);
    }
  }
  operand() {
    const tok = this.next();
    if (tok.startsWith(":")) return this.values[tok];
    return this.item?.[this.name(tok)];
  }

  // SET right-hand sides: a + b, a - b, if_not_exists(x, y)
  value() {
    let v = this.term();
    while (this.peek() === "+" || this.peek() === "-") {
      const op = this.next(), r = this.term();
      if (v === undefined || r === undefined) throw new Error("ValidationException: attribute does not exist");
      v = op === "+" ? v + r : v - r;
    }
    return v;
  }
  term() {
    if (this.peek() === "if_not_exists") {
      this.next(); this.expect("("); const n = this.name(this.next()); this.expect(","); const fallback = this.value(); this.expect(")");
      return this.item?.[n] ?? fallback;
    }
    return this.operand();
  }
}

function check(item, input) {
  if (!input.ConditionExpression) return;
  const ok = new Expr(input.ConditionExpression, item, input.ExpressionAttributeNames, input.ExpressionAttributeValues).or();
  if (!ok) throw new ConditionalCheckFailed();
}

function applyUpdate(item, input) {
  const next = structuredClone(item ?? { ...input.Key });
  const e = new Expr(input.UpdateExpression, item, input.ExpressionAttributeNames, input.ExpressionAttributeValues);
  while (e.peek()) {
    const clause = e.next();
    do {
      if (e.peek() === ",") e.next();
      const target = e.name(e.next());
      if (clause === "SET") { e.expect("="); next[target] = e.value(); }
      else if (clause === "ADD") { next[target] = (next[target] ?? 0) + e.operand(); }
      else if (clause === "REMOVE") { delete next[target]; }
      else throw new Error(`fakeddb: clause ${clause}`);
    } while (e.peek() === ",");
  }
  return next;
}

export class FakeDDB {
  constructor() {
    this.tables = new Map();
    this.calls = [];
    /** Runs before a command is applied (tests use it to interleave a concurrent write). */
    this.before = null;
  }
  table(name) {
    if (!this.tables.has(name)) this.tables.set(name, new Map());
    return this.tables.get(name);
  }
  static key(k) { return JSON.stringify(Object.entries(k).sort()); }
  get(table, key) { return this.table(table).get(FakeDDB.key(key)); }
  put(table, item, keyNames) {
    const key = Object.fromEntries(keyNames.map((k) => [k, item[k]]));
    this.table(table).set(FakeDDB.key(key), structuredClone(item));
  }
  keyOf(input) { return input.Key ?? keyFor(input.TableName, input.Item); }

  async send(cmd) {
    const kind = cmd.constructor.name.replace(/Command$/, "");
    const input = cmd.input;
    this.calls.push({ kind, input });
    if (this.before) await this.before(kind, input);
    switch (kind) {
      case "Get": return { Item: structuredClone(this.get(input.TableName, input.Key)) };
      case "Put": {
        const key = this.keyOf(input);
        check(this.get(input.TableName, key), input);
        this.table(input.TableName).set(FakeDDB.key(key), structuredClone(input.Item));
        return {};
      }
      case "Update": {
        const old = this.get(input.TableName, input.Key);
        check(old, input);
        const next = applyUpdate(old, input);
        this.table(input.TableName).set(FakeDDB.key(input.Key), next);
        return input.ReturnValues === "ALL_NEW" ? { Attributes: structuredClone(next) } : {};
      }
      case "Delete": this.table(input.TableName).delete(FakeDDB.key(input.Key)); return {};
      case "Query": {
        const [hashName] = Object.keys(input.ExpressionAttributeValues).filter((k) => k === ":u");
        const userId = input.ExpressionAttributeValues[hashName];
        const since = input.ExpressionAttributeValues[":since"];
        const Items = [...this.table(input.TableName).values()]
          .filter((it) => it.userId === userId && (since === undefined || it.day >= since))
          .map((it) => structuredClone(it));
        return { Items };
      }
      case "TransactWrite": {
        const ops = input.TransactItems.map((op) => {
          const [type, i] = Object.entries(op)[0];
          const key = type === "Put" ? this.keyOf(i) : i.Key;
          return { type, i, key };
        });
        const reasons = ops.map(({ i, key }) => {
          try { check(this.get(i.TableName, key), i); return { Code: "None" }; } catch { return { Code: "ConditionalCheckFailed" }; }
        });
        if (reasons.some((r) => r.Code !== "None")) {
          const e = new Error("Transaction cancelled");
          e.name = "TransactionCanceledException";
          e.CancellationReasons = reasons;
          throw e;
        }
        for (const { type, i, key } of ops) {
          const next = type === "Put" ? structuredClone(i.Item) : applyUpdate(this.get(i.TableName, key), i);
          this.table(i.TableName).set(FakeDDB.key(key), next);
        }
        return {};
      }
      default: throw new Error(`fakeddb: ${kind} not supported`);
    }
  }
}

const KEYS = { promo: ["code", "sk"], ledger: ["userId", "at"], daily: ["userId", "day"] };
function keyFor(table, item) {
  const names = table.includes("promo") ? KEYS.promo : table.includes("ledger") ? KEYS.ledger
    : table.includes("daily") ? KEYS.daily : ["userId"];
  return Object.fromEntries(names.map((k) => [k, item[k]]));
}
