import fs from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

const BUILD_WRAPPER_INSTALLER_PATH = path.resolve(
  import.meta.dirname,
  "../../scripts/build-wrapper-installer.ps1",
);
const SMOKE_TEST_WINDOWS_PATH = path.resolve(
  import.meta.dirname,
  "../../scripts/smoke-test-windows.ps1",
);

describe("build-wrapper-installer.ps1", () => {
  it("stages into a short temp root and emits wrapper diagnostics artifacts", () => {
    const script = fs.readFileSync(BUILD_WRAPPER_INSTALLER_PATH, "utf8");

    expect(script).toContain("New-ElizaHomeWindowsShortTempRoot");
    expect(script).toContain("windows-installer-contract.json");
    expect(script).toContain("windows-installer.iss");
    expect(script).toContain("windows-installer-build.log");
    expect(script).toContain("staged-launcher-missing");
    expect(script).toContain("staged-runtime-missing");
    expect(script).toContain("installed-path-too-long");
    expect(script).toContain("Get-ElizaHomeInstalledPathLayoutDiagnostic");
    expect(script).toContain('validationStatus = "compiler_failed"');
  });
});

describe("smoke-test-windows.ps1", () => {
  it("requires the wrapper manifest and emits explicit contract failures", () => {
    const script = fs.readFileSync(SMOKE_TEST_WINDOWS_PATH, "utf8");

    expect(script).toContain("windows-installer-contract.json");
    expect(script).toContain('reason = "payload-shape-invalid"');
    expect(script).toContain('reason = "iss-source-path-invalid"');
    expect(script).toContain('reason = "staged-launcher-missing"');
    expect(script).toContain('reason = "staged-runtime-missing"');
    expect(script).toContain('reason = "installer-output-missing"');
  });
});

describe("windows-installer-common.ps1", () => {
  it("uses the short LocalAppData install root for Windows compatibility", () => {
    const script = fs.readFileSync(
      path.resolve(
        import.meta.dirname,
        "../../scripts/windows-installer-common.ps1",
      ),
      "utf8",
    );

    expect(script).toContain('Join-Path $LocalAppData "EH"');
    expect(script).toContain("AppRoot = $appRoot");
    expect(script).toContain(
      'LauncherPath = Join-Path $appRoot "bin\\launcher.exe"',
    );
    expect(script).toContain("Get-ElizaHomeInstalledPathLayoutDiagnostic");
  });
});
