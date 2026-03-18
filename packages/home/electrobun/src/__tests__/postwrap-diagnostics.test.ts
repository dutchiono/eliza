import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { describe, expect, it } from "vitest";

import {
  detectBundleLayer,
  main,
  resolveBundleLayout,
  resolveDiagnosticsOutputPath,
  resolveWrapperBundlePath,
} from "../../scripts/postwrap-diagnostics";

describe("resolveWrapperBundlePath", () => {
  it("accepts an explicit wrapper path", () => {
    expect(resolveWrapperBundlePath(["/tmp/Eliza Home.app"], {})).toBe(
      "/tmp/Eliza Home.app",
    );
  });

  it("uses ELECTROBUN_WRAPPER_BUNDLE_PATH when present", () => {
    expect(
      resolveWrapperBundlePath([], {
        ELECTROBUN_WRAPPER_BUNDLE_PATH: "/tmp/Eliza Home.app",
      }),
    ).toBe("/tmp/Eliza Home.app");
  });

  it("falls back to the matching bundle inside ELECTROBUN_BUILD_DIR", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "postwrap-diag-"));
    const stableBundle = path.join(tempDir, "Eliza Home.app");
    const canaryBundle = path.join(tempDir, "Eliza Home-canary.app");
    fs.mkdirSync(stableBundle, { recursive: true });
    fs.mkdirSync(canaryBundle, { recursive: true });

    expect(
      resolveWrapperBundlePath([], {
        ELECTROBUN_APP_NAME: "Eliza Home canary",
        ELECTROBUN_BUILD_DIR: tempDir,
      }),
    ).toBe(canaryBundle);
  });
});

describe("resolveBundleLayout", () => {
  it("uses macOS app bundle paths", () => {
    expect(resolveBundleLayout("/tmp/Eliza Home.app", "macos")).toEqual({
      binaryDir: "/tmp/Eliza Home.app/Contents/MacOS",
      resourcesDir: "/tmp/Eliza Home.app/Contents/Resources",
    });
  });

  it("uses bin/resources for non-mac wrappers", () => {
    expect(resolveBundleLayout("/tmp/Eliza Home", "linux")).toEqual({
      binaryDir: "/tmp/Eliza Home/bin",
      resourcesDir: "/tmp/Eliza Home/resources",
    });
  });
});

describe("detectBundleLayer", () => {
  it("reports wrapped archive bundles when resources contain tarballs", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "postwrap-layer-"));
    const bundleRoot = path.join(tempDir, "win-wrapper");
    const resourcesDir = path.join(bundleRoot, "resources");
    fs.mkdirSync(resourcesDir, { recursive: true });
    fs.writeFileSync(path.join(resourcesDir, "abc123.tar.zst"), "placeholder");

    expect(
      detectBundleLayer(
        bundleRoot,
        "win",
        path.join(bundleRoot, "bin"),
        resourcesDir,
      ),
    ).toBe("wrapped_archive_bundle");
  });
});

describe("resolveDiagnosticsOutputPath", () => {
  it("writes into ELECTROBUN_BUILD_DIR when available", () => {
    expect(
      resolveDiagnosticsOutputPath("/tmp/Eliza Home.app", {
        ELECTROBUN_BUILD_DIR: "/tmp/build",
      }),
    ).toBe("/tmp/build/wrapper-diagnostics.json");
  });

  it("falls back to the wrapper parent directory", () => {
    expect(resolveDiagnosticsOutputPath("/tmp/build/Eliza Home.app", {})).toBe(
      "/tmp/build/wrapper-diagnostics.json",
    );
  });
});

describe("main", () => {
  it("uses the CLI wrapper path argument when Electrobun passes it directly", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "postwrap-main-"));
    const wrapperBundle = path.join(tempDir, "Eliza Home");
    fs.mkdirSync(path.join(wrapperBundle, "bin"), { recursive: true });
    fs.mkdirSync(path.join(wrapperBundle, "resources"), { recursive: true });

    main([wrapperBundle], {
      ELECTROBUN_ARCH: "x64",
      ELECTROBUN_OS: "linux",
    });

    const diagnosticsPath = path.join(tempDir, "wrapper-diagnostics.json");
    const diagnostics = JSON.parse(
      fs.readFileSync(diagnosticsPath, "utf8"),
    ) as {
      binaryDir: string;
      bundleLayer: string;
      os: string;
      outputPath: string;
      resourcesDir: string;
      wrapperBundlePath: string;
    };

    expect(diagnostics).toMatchObject({
      binaryDir: path.join(wrapperBundle, "bin"),
      bundleLayer: "raw_bundle",
      os: "linux",
      outputPath: diagnosticsPath,
      resourcesDir: path.join(wrapperBundle, "resources"),
      wrapperBundlePath: wrapperBundle,
    });
  });
});
