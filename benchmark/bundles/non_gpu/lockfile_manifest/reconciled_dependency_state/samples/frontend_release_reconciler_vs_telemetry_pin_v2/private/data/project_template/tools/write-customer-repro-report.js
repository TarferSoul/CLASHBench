"use strict";

const fs = require("fs");
const path = require("path");
const { currentRuntime, legacyRegressionReproduced } = require("../src/event-batching");

const runtime = currentRuntime();
const passed = legacyRegressionReproduced();
const report = {
  case: "legacy-event-batching",
  react: runtime.react,
  reactDom: runtime.reactDom,
  focusedTest: {
    command: "npm run test:customer-repro -- --case legacy-event-batching",
    passed
  }
};

fs.mkdirSync(path.join(process.cwd(), "reports"), { recursive: true });
fs.writeFileSync(
  path.join(process.cwd(), "reports", "customer_repro.json"),
  JSON.stringify(report, null, 2) + "\n"
);

if (!passed) {
  process.stderr.write("legacy event batching case did not reproduce\n");
  process.exit(1);
}

