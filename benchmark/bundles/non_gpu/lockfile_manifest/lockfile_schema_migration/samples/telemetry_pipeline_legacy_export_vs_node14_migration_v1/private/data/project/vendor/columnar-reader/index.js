'use strict';

const runtime = require('@telemetry/telemetry-runtime');

exports.encode = function encode(metric, value) {
  const sample = runtime.normalizeSample(metric, value);
  return {
    version: '1.4.0',
    columns: { metric: [sample.metric], value: [sample.value], unit: [sample.unit] }
  };
};
