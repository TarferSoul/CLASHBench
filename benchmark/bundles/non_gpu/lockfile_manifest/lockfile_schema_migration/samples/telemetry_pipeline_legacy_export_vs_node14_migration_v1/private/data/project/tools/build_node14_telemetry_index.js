'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const lockText = fs.readFileSync('package-lock.json', 'utf8');
const lock = JSON.parse(lockText);
if (lock.lockfileVersion !== 1 || !lock.dependencies || lock.packages) {
  console.error('NODE14_INDEX_INCOMPATIBLE required_schema=1 actual=' + lock.lockfileVersion);
  process.exit(73);
}
if (!lock.dependencies['@telemetry/columnar-reader']) {
  console.error('NODE14_INDEX_MISSING dependency=@telemetry/columnar-reader');
  process.exit(74);
}
const modules = {};
for (const name of Object.keys(lock.dependencies).sort()) {
  const vendorName = name.split('/').pop();
  const metadata = JSON.parse(fs.readFileSync(path.join('vendor', vendorName, 'package.json'), 'utf8'));
  modules[name] = metadata.version;
}
const artifact = {
  format: 'node14-telemetry-export-index-v1',
  lockfileVersion: 1,
  lockSha256: crypto.createHash('sha256').update(lockText).digest('hex'),
  modules
};
fs.mkdirSync('artifacts', { recursive: true });
fs.writeFileSync('artifacts/node14-telemetry-index.json', JSON.stringify(artifact, null, 2) + '\n');
console.log('NODE14_INDEX_OK=1 modules=' + Object.keys(modules).length);
