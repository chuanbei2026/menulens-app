// Per-request DynamoDB accounting. Every command sent through an instrumented client is timed and
// asked for its consumed capacity; the totals are attributed to the current request (via
// AsyncLocalStorage) and end up in that request's log line and metrics.
import { AsyncLocalStorage } from "node:async_hooks";

export const requestScope = new AsyncLocalStorage();

/** Wraps `client.send` in place and returns the client. */
export function instrument(client) {
  const send = client.send.bind(client);
  client.send = async (command, ...rest) => {
    if (command?.input && command.input.ReturnConsumedCapacity === undefined) {
      command.input.ReturnConsumedCapacity = "TOTAL";
    }
    const stats = requestScope.getStore()?.ddb;
    const started = performance.now();
    try {
      const result = await send(command, ...rest);
      if (stats) record(stats, command, performance.now() - started, result?.ConsumedCapacity);
      return result;
    } catch (e) {
      if (stats) {
        record(stats, command, performance.now() - started);
        // Conditional failures are expected (lock contention, already-granted months); count them apart.
        if (e?.name === "ConditionalCheckFailedException") stats.conditionalFailures += 1;
        else stats.errors += 1;
      }
      throw e;
    }
  };
  return client;
}

/** Per-request scope: DynamoDB stats plus background writes to await before the request ends. */
export function newScope() {
  return { ddb: newStats(), pending: [] };
}

export function newStats() {
  return { calls: 0, ms: 0, capacityUnits: 0, conditionalFailures: 0, errors: 0, ops: {} };
}

function record(stats, command, ms, consumed) {
  const op = command?.constructor?.name?.replace(/Command$/, "") ?? "Unknown";
  stats.calls += 1;
  stats.ms += ms;
  stats.ops[op] = (stats.ops[op] ?? 0) + 1;
  if (consumed?.CapacityUnits) stats.capacityUnits += consumed.CapacityUnits;
}

/** Flat fields for the request log line. */
export function summarize(stats) {
  return {
    ddbCalls: stats.calls,
    ddbMs: Math.round(stats.ms),
    ddbCapacityUnits: Math.round(stats.capacityUnits * 10) / 10,
    ddbConditionalFailures: stats.conditionalFailures,
    ddbErrors: stats.errors,
    ddbOps: stats.ops,
  };
}
