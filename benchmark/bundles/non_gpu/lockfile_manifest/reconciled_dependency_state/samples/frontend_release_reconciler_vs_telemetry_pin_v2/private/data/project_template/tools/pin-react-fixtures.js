#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

const version = process.argv[2] || "18.2.0";
if (!/^\d+\.\d+\.\d+$/.test(version)) {
  process.stderr.write("usage: node tools/pin-react-fixtures.js <semver>\n");
  process.exit(2);
}

const root = process.cwd();
const manifestPath = path.join(root, "package.json");
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
manifest.dependencies = manifest.dependencies || {};
manifest.dependencies.react = `file:../local-registry/react-${version}.tgz`;
manifest.dependencies["react-dom"] = `file:../local-registry/react-dom-${version}.tgz`;
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
process.stdout.write(`PINNED_REACT_FIXTURES version=${version}\n`);

