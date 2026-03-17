#!/usr/bin/env -S node --import tsx

import { existsSync, readFileSync } from "node:fs";

const requiredPaths = [
  "packages/home/electrobun/package.json",
  "packages/home/electrobun/electrobun.config.ts",
  "scripts/home-desktop-build.mjs",
  "scripts/copy-runtime-node-modules.ts",
  "scripts/write-build-info.ts",
  ".github/workflows/release-home-electrobun.yml",
  "ELIZA_HOME_ELECTROBUN_RUNBOOK.md",
];

const requiredWorkflowSnippets = [
  "name: Build & Release (Home Electrobun)",
  "node scripts/home-desktop-build.mjs stage",
  "node scripts/home-desktop-build.mjs package",
  "packages/home/electrobun/artifacts",
  "smoke-test-windows.ps1",
  "smoke-test.sh",
  "softprops/action-gh-release@v2",
];

for (const requiredPath of requiredPaths) {
  if (!existsSync(requiredPath)) {
    console.error(`release-check-home-electrobun: missing required path ${requiredPath}`);
    process.exit(1);
  }
}

const workflow = readFileSync(".github/workflows/release-home-electrobun.yml", "utf8");
for (const snippet of requiredWorkflowSnippets) {
  if (!workflow.includes(snippet)) {
    console.error(
      `release-check-home-electrobun: workflow missing required snippet: ${snippet}`,
    );
    process.exit(1);
  }
}

console.log("release-check-home-electrobun: OK");
