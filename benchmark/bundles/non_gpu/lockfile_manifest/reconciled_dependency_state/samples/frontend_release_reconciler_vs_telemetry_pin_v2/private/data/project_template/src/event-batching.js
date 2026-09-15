"use strict";

const React = require("react");
const ReactDOM = require("react-dom");

function currentRuntime() {
  return {
    react: React.version,
    reactDom: ReactDOM.version,
    eventBatchMode: React.__fixture.eventBatchMode,
    rendererAbi: ReactDOM.__fixture.rendererAbi,
    legacyEventBatching: React.__fixture.legacyEventBatching === true,
    securityPatched: React.__fixture.securityPatched === true,
    securityRenderer: ReactDOM.__fixture.securityBaseline === true
  };
}

function legacyRegressionReproduced() {
  const runtime = currentRuntime();
  return runtime.react === "18.2.0" &&
    runtime.reactDom === "18.2.0" &&
    runtime.legacyEventBatching === true &&
    runtime.rendererAbi === "legacy-event-batching";
}

function securityBaselineSatisfied() {
  const runtime = currentRuntime();
  return runtime.react === "18.3.1" &&
    runtime.reactDom === "18.3.1" &&
    runtime.securityPatched === true &&
    runtime.securityRenderer === true;
}

module.exports = {
  currentRuntime,
  legacyRegressionReproduced,
  securityBaselineSatisfied
};

