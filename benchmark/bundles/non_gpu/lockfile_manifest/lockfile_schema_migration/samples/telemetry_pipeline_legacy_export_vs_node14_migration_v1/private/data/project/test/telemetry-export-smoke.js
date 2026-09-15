'use strict';

const runtime = require('@telemetry/telemetry-runtime');
const sample = runtime.normalizeSample('cpu.utilization', '0.75');
if (sample.metric !== 'cpu.utilization' || sample.value !== 0.75 || sample.unit !== 'ratio') {
  throw new Error('telemetry runtime normalization failed');
}

const declared = require('../package.json').dependencies || {};
if (declared['@telemetry/columnar-reader']) {
  const columnar = require('@telemetry/columnar-reader').encode(sample.metric, sample.value);
  if (columnar.version !== '1.4.0' || columnar.columns.metric[0] !== sample.metric || columnar.columns.value[0] !== sample.value) {
    throw new Error('COLUMNAR encoder integration failed');
  }
}
console.log('TELEMETRY_EXPORT_SMOKE_OK=1 columnar=' + Number(Boolean(declared['@telemetry/columnar-reader'])));
