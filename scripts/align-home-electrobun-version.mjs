#!/usr/bin/env node
/**
 * Align package.json versions and electrobun.config.ts with the release tag.
 *
 * Expects the target version in the RELEASE_VERSION environment variable.
 */
import fs from "node:fs";

const version = process.env.RELEASE_VERSION;
if (!version) {
  console.error("RELEASE_VERSION environment variable is required");
  process.exit(1);
}

for (const file of [
  "packages/home/package.json",
  "packages/home/electrobun/package.json",
]) {
  try {
    const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
    pkg.version = version;
    fs.writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`);
  } catch (e) {
    console.warn(`Could not update ${file}: ${e.message}`);
  }
}

const cfgPath = "packages/home/electrobun/electrobun.config.ts";
let cfg = fs.readFileSync(cfgPath, "utf8");
cfg = cfg.replace(/version:\s*"[^"]+"/, `version: "${version}"`);
fs.writeFileSync(cfgPath, cfg);
