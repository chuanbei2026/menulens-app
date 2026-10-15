import assert from "node:assert/strict";
import { test } from "node:test";
import { instrument, newStats, requestScope, summarize } from "../src/ddbstats.mjs";

class GetItemCommand { constructor(input) { this.input = input; } }
class UpdateItemCommand { constructor(input) { this.input = input; } }

test("attributes calls, capacity and conditional failures to the current request only", async () => {
  const fake = { async send(cmd) {
    if (cmd.input.fail) { const e = new Error("x"); e.name = "ConditionalCheckFailedException"; throw e; }
    assert.equal(cmd.input.ReturnConsumedCapacity, "TOTAL"); // injected
    return { ConsumedCapacity: { CapacityUnits: 0.5 } };
  } };
  const client = instrument(fake);
  const a = newStats(), b = newStats();
  await Promise.all([
    requestScope.run({ ddb: a }, async () => {
      await client.send(new GetItemCommand({}));
      await client.send(new UpdateItemCommand({}));
      await assert.rejects(client.send(new UpdateItemCommand({ fail: true })));
    }),
    requestScope.run({ ddb: b }, () => client.send(new GetItemCommand({}))),
  ]);
  const s = summarize(a);
  assert.equal(s.ddbCalls, 3);
  assert.equal(s.ddbCapacityUnits, 1);
  assert.equal(s.ddbConditionalFailures, 1);
  assert.equal(s.ddbErrors, 0);
  assert.deepEqual(s.ddbOps, { GetItem: 1, UpdateItem: 2 });
  assert.equal(summarize(b).ddbCalls, 1); // concurrent request kept separate
});
