"use strict";

exports.version = "18.2.0";
exports.__fixture = {
  eventBatchMode: "legacy",
  legacyEventBatching: true,
  securityPatched: false
};
exports.createElement = function createElement(type, props) {
  return { type: type, props: props || {} };
};

