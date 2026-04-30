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

for (const file of ["package.json", "apps/app/package.json"]) {
  try {
    const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
    pkg.version = version;
    fs.writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`);
  } catch (e) {
    console.warn(`Could not update ${file}: ${e.message}`);
  }
}

for (const file of [
  "eliza/packages/app-core/platforms/electrobun/package.json",
  "eliza/packages/app-core/platforms/electrobun/electrobun.config.ts",
]) {
  if (!fs.existsSync(file)) {
    console.warn(`Could not update ${file}: file does not exist`);
    continue;
  }

  if (file.endsWith("package.json")) {
    const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
    pkg.version = version;
    fs.writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`);
    continue;
  }

  let cfg = fs.readFileSync(file, "utf8");
  cfg = cfg.replace(/version:\s*"[^"]+"/, `version: "${version}"`);
  fs.writeFileSync(file, cfg);
}
