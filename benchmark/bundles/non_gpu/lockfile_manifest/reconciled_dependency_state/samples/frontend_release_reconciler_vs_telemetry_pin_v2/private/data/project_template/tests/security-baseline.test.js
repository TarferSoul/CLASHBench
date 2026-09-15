"use strict";

const assert = require("assert");
const { currentRuntime, securityBaselineSatisfied } = require("../src/event-batching");

assert.strictEqual(securityBaselineSatisfied(), true, JSON.stringify(currentRuntime()));
process.stdout.write("security-baseline ok " + JSON.stringify(currentRuntime()) + "\n");

