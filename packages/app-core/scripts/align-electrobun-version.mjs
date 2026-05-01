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

// electrobun config lives at packages/app-core/platforms/electrobun/ inside
// eliza now; keep the legacy apps/app/electrobun/ paths in the candidate list
// for repos that haven't migrated yet.
const electrobunDirs = [
  "eliza/packages/app-core/platforms/electrobun",
  "packages/app-core/platforms/electrobun",
  "apps/app/electrobun",
];

const packageJsonCandidates = [
  "package.json",
  "apps/app/package.json",
  ...electrobunDirs.map((dir) => `${dir}/package.json`),
];

for (const file of packageJsonCandidates) {
  try {
    const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
    pkg.version = version;
    fs.writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`);
  } catch (e) {
    console.warn(`Could not update ${file}: ${e.message}`);
  }
}

const cfgPath = electrobunDirs
  .map((dir) => `${dir}/electrobun.config.ts`)
  .find((candidate) => fs.existsSync(candidate));
if (!cfgPath) {
  console.error(
    `electrobun.config.ts not found in any candidate location: ${electrobunDirs.join(", ")}`,
  );
  process.exit(1);
}
let cfg = fs.readFileSync(cfgPath, "utf8");
cfg = cfg.replace(/version:\s*"[^"]+"/, `version: "${version}"`);
fs.writeFileSync(cfgPath, cfg);
