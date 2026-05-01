# Milady Electrobun shell (`@miladyai/electrobun`)

This package is the **native desktop wrapper** around the Milady companion UI: it creates the `BrowserWindow`, loads the Vite renderer, wires RPC to native modules, and (on macOS) applies vibrancy, traffic-light layout, and **frameless window chrome** (drag + resize).

## Why this exists

Electrobun is the **shell**, not the agent runtime. The same Milady runtime (`dist/` / packaged `milady-dist`) is used from CLI, server, and desktop; this folder only hosts **main-process** TypeScript, **preload**, **native `.mm` helpers**, and Electrobun config.

## macOS window chrome (read this before editing)

`titleBarStyle: "hiddenInset"` removes the standard title bar. **WKWebView** then covers the client area. **Dragging** and **inner-edge resizing** are handled with **transparent native views above the web view** so AppKit owns hit testing and cursor rects — not the HTML layer.

- **Why:** WebKit applies page cursors continuously; `NSTrackingArea` under the web view could not reliably show resize cursors or receive drags, and competing `NSCursor` updates caused flicker.
- **Docs (WHYs, file map, build):** [Electrobun macOS window chrome](https://docs.milady.ai/guides/electrobun-mac-window-chrome) (or `docs/guides/electrobun-mac-window-chrome.md` in-repo).
- **Code:** `native/macos/window-effects.mm` — `ElectrobunNativeDragView` (top strip), `MiladyResizeStripView` (right / bottom / BR), `miladyChromeDepthPoints` (per-screen thickness when host passes `height ≤ 0`).
- **Main process:** `src/index.ts` — `applyMacOSWindowEffects`, `alignChrome` on resize, **move** (display changes), and webview **dom-ready** so strips stay above WKWebView after layout.
- **FFI:** `src/native/mac-window-effects.ts`.

### Rebuild native effects after changing `.mm`

```bash
cd apps/app/electrobun && bun run build:native-effects
```

Produces `src/libMacWindowEffects.dylib` (consumed via Bun FFI at runtime).

## Common commands

| Command | Purpose |
|--------|---------|
| `bun run dev` | Preload build + `electrobun dev` |
| `bun run build` | Preload + production Electrobun build |
| `bun run test` | Vitest (`src/__tests__`, etc.) |
| `bun run build:native-effects` | Compile macOS `window-effects.mm` → dylib |

## Fast Windows CI Smoke Repro

Use this when a GitHub Actions Windows release run already built an installer and
failed at `Smoke test packaged Windows app`. This skips the full CI rebuild and
replays the important failing layer locally: install the real Inno `.exe`, launch
the installed `bin\launcher.exe`, and use isolated `APPDATA`/`LOCALAPPDATA`.

It is not a full replacement for CI. It does not prove checkout, submodule
fetching, or workflow `GITHUB_ENV` propagation. It does prove whether the built
installer can install and start under the same smoke script.

Prereqs: Windows, `gh auth login`, PowerShell 7 (`pwsh`), and a checkout of the
same branch as the run.

```powershell
# From the Milady repo root on Windows.
$runId = "25229141932"
$repo = "dutchiono/milady"
$downloadDir = Join-Path $PWD ".tmp-run-$runId\installer"

Remove-Item $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# On smoke failure, CI uploads the installer plus Inno log under this artifact.
# For a successful canary run, use electrobun-windows-x64-public-installer instead.
gh run download $runId --repo $repo --name electrobun-windows-installer-debug --dir $downloadDir

$installer = Get-ChildItem $downloadDir -Recurse -File -Filter "*Setup*.exe" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $installer) {
  throw "No installer .exe found under $downloadDir"
}

# Keep this short and user-writable. Do not hard-code C:\; path length is part
# of what the Windows smoke is validating.
$smokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "milady-ci-smoke"
Remove-Item $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $smokeRoot | Out-Null

$env:RUNNER_TEMP = $smokeRoot
$env:ELIZA_WINDOWS_SMOKE_REQUIRE_INSTALLER = "1"
$env:ELIZA_TEST_WINDOWS_ARTIFACTS_DIR = $installer.DirectoryName
$env:ELIZA_TEST_WINDOWS_BUILD_DIR = $installer.DirectoryName
$env:ELIZA_TEST_WINDOWS_INSTALL_DIR = Join-Path $smokeRoot "el"
$env:ELIZA_TEST_WINDOWS_APPDATA_PATH = Join-Path $smokeRoot "appdata"
$env:ELIZA_TEST_WINDOWS_LOCALAPPDATA_PATH = Join-Path $smokeRoot "localappdata"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  eliza\packages\app-core\scripts\run-windows-smoke-launcher.ps1 `
  eliza\packages\app-core\platforms\electrobun\scripts\smoke-test-windows.ps1 `
  -ArtifactsDir $installer.DirectoryName `
  -BuildDir $installer.DirectoryName
```

If this fails faster than CI, inspect the smoke output first. The useful files are
under `$smokeRoot`: the Inno log, startup state/events JSON, and
`appdata\Milady\milady-startup.log` (plus the legacy `appdata\Eliza` log if
present).

## WebGPU status log and macOS version (Darwin)

Startup logs **`[WebGPU Browser] …`** use **`os.release()`**, which reports the **Darwin** kernel major (e.g. **25.x** on **macOS 26** Tahoe)—not the macOS marketing major in About This Mac. **Why it matters:** a single **`Darwin − 9`** rule matched macOS 11–15 but labeled Tahoe as “macOS 16” and wrong-feature-gated WKWebView WebGPU. **`getMacOSMajorVersion()`** in **`src/native/webgpu-browser-support.ts`** implements the two-part mapping; full **WHYs** and the reference table: **[Darwin vs macOS version (Electrobun WebGPU)](../../docs/apps/electrobun-darwin-macos-webgpu-version.md)**.

## Related repo docs

- [Desktop app](https://docs.milady.ai/apps/desktop) — install, runtime modes, native modules.
- [Electrobun startup](../../docs/electrobun-startup.md) — agent/bootstrap guards in `src/native/agent.ts`.
- [Darwin vs macOS version (WebGPU)](../../docs/apps/electrobun-darwin-macos-webgpu-version.md) — `uname -r` vs macOS 26+, WebGPU gating rationale.
