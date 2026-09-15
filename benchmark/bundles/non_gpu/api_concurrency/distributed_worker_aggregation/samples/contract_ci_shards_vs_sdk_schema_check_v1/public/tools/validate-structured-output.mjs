#!/usr/bin/env node
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import path from "node:path";

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (!value.startsWith("--")) {
      throw new Error(`unexpected positional argument: ${value}`);
    }
    const key = value.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith("--")) {
      throw new Error(`missing value for --${key}`);
    }
    args[key] = next;
    i += 1;
  }
  return args;
}

function readJsonl(filePath) {
  return fs
    .readFileSync(filePath, "utf8")
    .split(/\r?\n/)
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line));
}

function requestJson(urlText, payload, timeoutMs) {
  const target = new URL(urlText);
  const body = Buffer.from(JSON.stringify(payload));
  const client = target.protocol === "https:" ? https : http;
  const options = {
    method: "POST",
    hostname: target.hostname,
    port: target.port || (target.protocol === "https:" ? 443 : 80),
    path: `${target.pathname}${target.search}`,
    headers: {
      "content-type": "application/json",
      "content-length": body.length,
    },
    timeout: timeoutMs,
  };
  const started = Date.now();
  return new Promise((resolve) => {
    const req = client.request(options, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let parsed = {};
        try {
          parsed = text ? JSON.parse(text) : {};
        } catch {
          parsed = { raw: text };
        }
        resolve({ status: res.statusCode || 0, body: parsed, elapsed_ms: Date.now() - started });
      });
    });
    req.on("timeout", () => {
      req.destroy(new Error("request timeout"));
    });
    req.on("error", (error) => {
      resolve({ status: 0, error: String(error.message || error), elapsed_ms: Date.now() - started });
    });
    req.write(body);
    req.end();
  });
}

function getJson(urlText, timeoutMs) {
  const target = new URL(urlText);
  const client = target.protocol === "https:" ? https : http;
  const options = {
    method: "GET",
    hostname: target.hostname,
    port: target.port || (target.protocol === "https:" ? 443 : 80),
    path: `${target.pathname}${target.search}`,
    timeout: timeoutMs,
  };
  return new Promise((resolve) => {
    const req = client.request(options, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"));
        } catch {
          resolve({});
        }
      });
    });
    req.on("timeout", () => {
      req.destroy(new Error("request timeout"));
    });
    req.on("error", () => resolve({}));
    req.end();
  });
}

function parseAssistantContent(body) {
  const raw = body?.choices?.[0]?.message?.content;
  if (typeof raw !== "string") {
    throw new Error("missing assistant content");
  }
  return JSON.parse(raw);
}

function validateContent(fixture, content) {
  for (const field of fixture.expected_fields) {
    if (!(field in content)) {
      throw new Error(`missing field ${field}`);
    }
  }
  if (content.case_id !== fixture.id) {
    throw new Error("case id mismatch");
  }
  if (content.schema_name !== fixture.schema_name) {
    throw new Error("schema name mismatch");
  }
  if (content.schema_valid !== true) {
    throw new Error("schema_valid was not true");
  }
  if (!content.response_hash || typeof content.response_hash !== "string") {
    throw new Error("missing response_hash");
  }
}

async function evaluateCase(fixture, config, localState) {
  localState.active += 1;
  localState.peak = Math.max(localState.peak, localState.active);
  let response;
  try {
    response = await requestJson(
      config.baseUrl,
      {
        model: config.deployment,
        metadata: {
          tenant: config.tenant,
          owner: config.owner,
          run_id: config.runId,
          case_id: fixture.id,
          purpose: "structured_output_validation",
          schema_name: fixture.schema_name,
          expected_fields: fixture.expected_fields,
          deployment: config.deployment,
        },
        messages: [
          { role: "system", content: "Validate a structured-output SDK wrapper response." },
          { role: "user", content: JSON.stringify({ id: fixture.id, input: fixture.input }) },
        ],
        temperature: 0,
      },
      config.timeoutMs,
    );
  } finally {
    localState.active -= 1;
  }
  if (response.status !== 200) {
    const error = response.body?.error || {};
    return {
      ok: false,
      case_id: fixture.id,
      status: response.status,
      reason: error.type || response.error || "api_error",
      code: error.code || "",
      elapsed_ms: response.elapsed_ms,
    };
  }
  try {
    const content = parseAssistantContent(response.body);
    validateContent(fixture, content);
    return {
      ok: true,
      case_id: fixture.id,
      schema_name: fixture.schema_name,
      schema_valid: true,
      normalized: content.normalized,
      response_hash: content.response_hash,
      response_id: response.body.id || "",
      deployment: response.body.model || config.deployment,
      elapsed_ms: response.elapsed_ms,
    };
  } catch (error) {
    return {
      ok: false,
      case_id: fixture.id,
      status: response.status,
      reason: "invalid_structured_response",
      code: "",
      detail: String(error.message || error),
      elapsed_ms: response.elapsed_ms,
    };
  }
}

async function runPool(fixtures, concurrency, worker) {
  let index = 0;
  const results = [];
  const lanes = Array.from({ length: concurrency }, async () => {
    while (index < fixtures.length) {
      const current = fixtures[index];
      index += 1;
      results.push(await worker(current));
    }
  });
  await Promise.all(lanes);
  return results;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  for (const key of ["fixtures", "deployment", "tenant", "concurrency", "trace-dir", "report"]) {
    if (!args[key]) {
      throw new Error(`missing --${key}`);
    }
  }
  const concurrency = Number.parseInt(args.concurrency, 10);
  if (!Number.isInteger(concurrency) || concurrency < 1) {
    throw new Error("--concurrency must be a positive integer");
  }
  const fixtures = readJsonl(args.fixtures);
  const traceDir = args["trace-dir"];
  const reportPath = args.report;
  fs.rmSync(traceDir, { recursive: true, force: true });
  fs.mkdirSync(traceDir, { recursive: true });
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });

  const baseUrl = process.env.SDK_SCHEMA_BASE_URL || "http://127.0.0.1:25429/v1/chat/completions";
  const metricsUrl = process.env.SDK_SCHEMA_METRICS_URL || "http://127.0.0.1:25429/metrics";
  const config = {
    baseUrl,
    metricsUrl,
    deployment: args.deployment,
    tenant: args.tenant,
    owner: process.env.SDK_SCHEMA_OWNER || "sdk-structured-output-check",
    runId: process.env.SDK_SCHEMA_RUN_ID || "sdk-schema-validation",
    timeoutMs: Number.parseInt(process.env.B_REQUEST_TIMEOUT_MS || "7000", 10),
  };
  const localState = { active: 0, peak: 0 };
  const startedAt = new Date().toISOString();
  const rawResults = await runPool(fixtures, concurrency, (fixture) => evaluateCase(fixture, config, localState));
  rawResults.sort((left, right) => fixtures.findIndex((item) => item.id === left.case_id) - fixtures.findIndex((item) => item.id === right.case_id));
  const successes = rawResults.filter((item) => item.ok);
  const failures = rawResults.filter((item) => !item.ok);

  for (const row of successes) {
    const trace = { ...row };
    delete trace.ok;
    fs.writeFileSync(path.join(traceDir, `${row.case_id}.json`), `${JSON.stringify(trace, null, 2)}\n`);
  }
  if (failures.length > 0) {
    fs.writeFileSync(path.join(path.dirname(reportPath), "failed_requests.jsonl"), failures.map((item) => JSON.stringify(item)).join("\n") + "\n");
  }

  const metrics = await getJson(config.metricsUrl, 1500);
  const key = `${config.owner}/${config.runId}`;
  const observedPeak = Number(metrics?.peak_active_by_key?.[key] || localState.peak || 0);
  const completedByKey = Number(metrics?.completed_by_key?.[key] || 0);
  const rejectedByKey = Number(metrics?.rejected_by_key?.[key] || 0);
  const failedIds = failures.map((item) => item.case_id);
  const report = {
    deployment: args.deployment,
    tenant: args.tenant,
    owner: config.owner,
    run_id: config.runId,
    total_fixtures: fixtures.length,
    completed_fixtures: successes.length,
    trace_count: successes.length,
    schema_pass_rate: fixtures.length ? successes.length / fixtures.length : 0,
    retry_count: failures.filter((item) => item.status === 429).length,
    failed_fixture_ids: failedIds,
    failures,
    required_concurrency: concurrency,
    observed_peak_concurrency: observedPeak,
    local_peak_concurrency: localState.peak,
    gateway_capacity: metrics.capacity,
    gateway_completed: completedByKey,
    gateway_rejected: rejectedByKey,
    complete: successes.length === fixtures.length && failedIds.length === 0 && observedPeak >= concurrency,
    started_at: startedAt,
    finished_at: new Date().toISOString(),
  };
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  if (!report.complete) {
    console.log(
      `structured-output validation incomplete: completed=${successes.length}/${fixtures.length} peak=${observedPeak}/${concurrency} failures=${failures.length}`,
    );
    process.exit(1);
  }
  console.log(
    `structured-output validation complete: fixtures=${fixtures.length} schema_pass_rate=${report.schema_pass_rate.toFixed(3)} peak=${observedPeak}`,
  );
}

main().catch((error) => {
  console.error(error?.stack || String(error));
  process.exit(2);
});
