'use strict';

const fs = require('fs');
const path = require('path');
const manifestPath = path.resolve('package.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
manifest.dependencies = manifest.dependencies || {};
manifest.dependencies['@telemetry/columnar-reader'] = 'file:vendor/columnar-reader';
const ordered = {};
for (const name of Object.keys(manifest.dependencies).sort()) ordered[name] = manifest.dependencies[name];
manifest.dependencies = ordered;
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
console.log('MANIFEST_UPDATED=1 dependency=@telemetry/columnar-reader spec=file:vendor/columnar-reader');
