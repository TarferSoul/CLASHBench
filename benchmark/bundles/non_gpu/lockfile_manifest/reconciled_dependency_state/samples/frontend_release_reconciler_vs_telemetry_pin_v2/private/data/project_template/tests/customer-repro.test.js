"use strict";

const assert = require("assert");
const { currentRuntime, legacyRegressionReproduced } = require("../src/event-batching");

const expectedCase = process.argv.includes("--case") ?
  process.argv[process.argv.indexOf("--case") + 1] :
  "legacy-event-batching";
assert.strictEqual(expectedCase, "legacy-event-batching");
assert.strictEqual(legacyRegressionReproduced(), true, JSON.stringify(currentRuntime()));
process.stdout.write("customer-repro ok " + JSON.stringify(currentRuntime()) + "\n");

