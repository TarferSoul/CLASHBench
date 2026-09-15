'use strict';

const crypto = require('crypto');
const fs = require('fs');
const lockText = fs.readFileSync('package-lock.json', 'utf8');
const lock = JSON.parse(lockText);
if (lock.lockfileVersion !== 3 || !lock.packages || lock.dependencies) {
  console.error('MODERN_INDEX_INCOMPATIBLE required_schema=3 actual=' + lock.lockfileVersion);
  process.exit(75);
}
const packageKeys = Object.keys(lock.packages).filter((key) => key.startsWith('node_modules/')).sort();
if (!packageKeys.includes('node_modules/@telemetry/telemetry-runtime')) {
  console.error('MODERN_INDEX_MISSING dependency=@telemetry/telemetry-runtime');
  process.exit(76);
}
const artifact = {
  format: 'telemetry-pipeline-resolution-index-v3',
  lockfileVersion: 3,
  lockSha256: crypto.createHash('sha256').update(lockText).digest('hex'),
  packageKeys
};
fs.mkdirSync('artifacts', { recursive: true });
fs.writeFileSync('artifacts/modern-resolution-index.json', JSON.stringify(artifact, null, 2) + '\n');
console.log('MODERN_INDEX_OK=1 packages=' + packageKeys.length);
