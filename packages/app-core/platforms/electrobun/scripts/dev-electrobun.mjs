#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const cwd = process.cwd();
const baseEnv = {
  ...process.env,
  PATH: `${path.join(cwd, "scripts", "bin")}${path.delimiter}${process.env.PATH ?? ""}`,
};

const defaultBuildDir = path.join(cwd, "build", "dev-win-x64");

function runElectrobun(env = baseEnv) {
  return spawnSync("bunx", ["electrobun", "dev"], {
    cwd,
    env,
    stdio: "inherit",
    encoding: "utf8",
  });
}

function isWindowsLockFailure(output) {
  if (!output) return false;
  const text = output.toLowerCase();
  return text.includes("eacces") && text.includes("dev-win-x64");
}

function collectOutput(result) {
  return `${result?.stdout ?? ""}\n${result?.stderr ?? ""}`;
}

// Best-effort cleanup before first attempt.
if (process.platform === "win32") {
  try {
    fs.rmSync(defaultBuildDir, { recursive: true, force: true });
  } catch {
    // Electrobun can still succeed; ignore.
  }
}

let result = runElectrobun();
let output = collectOutput(result);

if (
  process.platform === "win32" &&
  result.status !== 0 &&
  isWindowsLockFailure(output)
) {
  const fallbackBuildDir = path.join(
    os.tmpdir(),
    `milady-electrobun-dev-${Date.now()}`,
  );
  fs.mkdirSync(fallbackBuildDir, { recursive: true });
  console.warn(
    `[electrobun-dev] Locked default build dir detected. Retrying with ELECTROBUN_BUILD_DIR=${fallbackBuildDir}`,
  );
  result = runElectrobun({
    ...baseEnv,
    ELECTROBUN_BUILD_DIR: fallbackBuildDir,
  });
}

process.exit(result.status ?? 1);
