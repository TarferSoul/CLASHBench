"use strict";

exports.version = "18.3.1";
exports.__fixture = {
  eventBatchMode: "patched",
  legacyEventBatching: false,
  securityPatched: true
};
exports.createElement = function createElement(type, props) {
  return { type: type, props: props || {}, patched: true };
};

