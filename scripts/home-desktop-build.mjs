#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const ROOT = process.cwd();
const HOME_DIR = path.join(ROOT, "packages", "home");
const ELECTROBUN_DIR = path.join(HOME_DIR, "electrobun");
const RUNTIME_DIR = path.join(ROOT, "packages", "autonomous");
const RUNTIME_DIST_DIR = path.join(RUNTIME_DIR, "dist");
const COMMAND_PREFIX = (process.env.ELIZA_HOME_DESKTOP_COMMAND_PREFIX ?? "")
  .trim()
  .split(/\s+/)
  .filter(Boolean);

const argv = process.argv.slice(2);
const command = argv[0] && !argv[0].startsWith("--") ? argv[0] : "build";
const flagStart = command === "build" && argv[0]?.startsWith("--") ? 0 : 1;
const args = argv.slice(flagStart);

const buildEnv = getArgValue(args, "env") ?? process.env.BUILD_ENV ?? "";
const buildWhisper = getBooleanArg(args, "build-whisper");

function fail(message, code = 1) {
  console.error(`[home-desktop-build] ${message}`);
  process.exit(code);
}

function getArgValue(argvItems, name) {
  const exact = `--${name}`;
  const prefixed = `--${name}=`;
  const index = argvItems.indexOf(exact);
  if (index >= 0) {
    const value = argvItems[index + 1];
    return value && !value.startsWith("--") ? value : null;
  }

  const inline = argvItems.find((item) => item.startsWith(prefixed));
  return inline ? inline.slice(prefixed.length) : null;
}

function getBooleanArg(argvItems, name) {
  const value = getArgValue(argvItems, name);
  if (value !== null) {
    return ["1", "true", "yes", "on"].includes(value.toLowerCase());
  }
  return argvItems.includes(`--${name}`);
}

function which(commandName) {
  const pathEnv = process.env.PATH ?? "";
  if (!pathEnv) return null;

  const isWindows = process.platform === "win32";
  const exts = isWindows
    ? (process.env.PATHEXT?.split(";").filter(Boolean) ?? [
        ".EXE",
        ".CMD",
        ".BAT",
        ".COM",
      ])
    : [""];

  for (const dir of pathEnv.split(path.delimiter).filter(Boolean)) {
    for (const ext of exts) {
      const suffix = isWindows && ext && !commandName.endsWith(ext) ? ext : "";
      const candidate = path.join(dir, `${commandName}${suffix}`);
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }
  }

  return null;
}

function buildInvocation(binary, binaryArgs = []) {
  if (COMMAND_PREFIX.length === 0) {
    return { command: binary, args: binaryArgs };
  }

  return {
    command: COMMAND_PREFIX[0],
    args: [...COMMAND_PREFIX.slice(1), binary, ...binaryArgs],
  };
}

function run(commandName, commandArgs, options = {}) {
  const { cwd = ROOT, env = process.env, label } = options;
  const invocation = buildInvocation(commandName, commandArgs);
  const rendered = [invocation.command, ...invocation.args].join(" ");
  console.log(`[home-desktop-build] ${label ?? rendered}`);

  const result = spawnSync(invocation.command, invocation.args, {
    cwd,
    env,
    stdio: "inherit",
  });

  if (result.status !== 0) {
    fail(
      `${rendered} failed with exit code ${result.status ?? 1}`,
      result.status ?? 1,
    );
  }
}

function runBun(commandArgs, options = {}) {
  const bun = which("bun");
  if (!bun) {
    fail('Could not find "bun" in PATH.');
  }
  run(bun, commandArgs, options);
}

function runNode(commandArgs, options = {}) {
  const node = which("node") ?? process.execPath;
  run(node, commandArgs, options);
}

function runPackageBinary(binary, binaryArgs, options = {}) {
  const bunx = which("bunx");
  if (bunx) {
    run(bunx, [binary, ...binaryArgs], options);
    return;
  }

  const npx = which("npx");
  if (npx) {
    run(npx, [binary, ...binaryArgs], options);
    return;
  }

  fail(`Could not find bunx or npx to run ${binary}.`);
}

function ensureAppDirs() {
  for (const dir of [HOME_DIR, ELECTROBUN_DIR, RUNTIME_DIR]) {
    if (!fs.existsSync(dir)) {
      fail(`Expected directory not found: ${dir}`);
    }
  }
}

function stageDesktopBuild() {
  ensureAppDirs();

  const installArgs = ["install"];
  if (process.env.CI === "true") {
    installArgs.push("--frozen-lockfile", "--ignore-scripts");
  }

  runBun(installArgs, {
    cwd: ROOT,
    label: "Ensuring workspace dependencies are installed",
  });

  runBun(["run", "build:dist"], {
    cwd: RUNTIME_DIR,
    label: "Building autonomous runtime bundle",
  });

  runNode(["--import", "tsx", "scripts/write-build-info.ts", RUNTIME_DIST_DIR], {
    cwd: ROOT,
    label: "Writing runtime build metadata",
  });

  runNode(
    [
      "--import",
      "tsx",
      "scripts/copy-runtime-node-modules.ts",
      "--scan-dir",
      path.relative(ROOT, RUNTIME_DIST_DIR),
      "--target-dist",
      path.relative(ROOT, RUNTIME_DIST_DIR),
    ],
    {
      cwd: ROOT,
      label: "Bundling runtime node_modules into packages/autonomous/dist",
    },
  );

  runPackageBinary("vite", ["build"], {
    cwd: HOME_DIR,
    label: "Building Home renderer bundle",
  });

  runBun(["run", "build:preload"], {
    cwd: ELECTROBUN_DIR,
    label: "Building Electrobun preload bridge",
  });

  if (process.platform === "darwin") {
    runBun(["run", "build:native-effects"], {
      cwd: ELECTROBUN_DIR,
      label: "Building native macOS effects dylib",
    });
  }

  if (
    buildWhisper &&
    (process.platform === "darwin" || process.platform === "linux")
  ) {
    runBun(["run", "build:whisper"], {
      cwd: ELECTROBUN_DIR,
      label: "Building whisper.cpp native binary",
    });
  }
}

function packageDesktopBuild() {
  ensureAppDirs();
  const packageArgs = ["run", "build"];
  if (buildEnv) {
    packageArgs.push("--", `--env=${buildEnv}`);
  }

  runBun(packageArgs, {
    cwd: ELECTROBUN_DIR,
    label: buildEnv
      ? `Packaging Home Electrobun app (env=${buildEnv})`
      : "Packaging Home Electrobun app",
  });
}

function runDesktopBuild() {
  const electrobun = which("electrobun");
  if (electrobun) {
    run(electrobun, ["run"], {
      cwd: ELECTROBUN_DIR,
      label: "Launching packaged Home Electrobun app",
    });
    return;
  }

  runPackageBinary("electrobun", ["run"], {
    cwd: ELECTROBUN_DIR,
    label: "Launching packaged Home Electrobun app",
  });
}

function printUsage() {
  console.log(`Usage: node scripts/home-desktop-build.mjs <command> [options]

Commands:
  stage    Build runtime/assets/preload inputs for desktop packaging
  package  Run electrobun build against the staged desktop inputs
  build    Run stage + package
  run      Run stage + package + electrobun run

Options:
  --env <channel>   Electrobun build env (e.g. canary, stable)
  --build-whisper   Build whisper.cpp on macOS/Linux during stage

Environment:
  ELIZA_HOME_DESKTOP_COMMAND_PREFIX   Prefix every spawned command, e.g. "arch -x86_64"
`);
}

switch (command) {
  case "stage":
    stageDesktopBuild();
    break;
  case "package":
    packageDesktopBuild();
    break;
  case "build":
    stageDesktopBuild();
    packageDesktopBuild();
    break;
  case "run":
    stageDesktopBuild();
    packageDesktopBuild();
    runDesktopBuild();
    break;
  case "help":
  case "--help":
  case "-h":
    printUsage();
    break;
  default:
    fail(`Unknown command: ${command}`);
}
