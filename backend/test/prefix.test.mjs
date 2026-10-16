import assert from "node:assert/strict";
import { test } from "node:test";
import { stripPrefix } from "../src/prefix.mjs";

test("the CloudFront prefix is stripped; bare paths from older builds pass through", () => {
  assert.equal(stripPrefix("/menu/credits"), "/credits");
  assert.equal(stripPrefix("/menu"), "/menu"); // a real route in ForeignMenu (POST /menu), never stripped
  assert.equal(stripPrefix("/menu/"), "/");
  assert.equal(stripPrefix("/credits"), "/credits");
  assert.equal(stripPrefix("/menu/menu"), "/menu"); // the menu relay through CloudFront
  assert.equal(stripPrefix("/menux/credits"), "/menux/credits");
});
