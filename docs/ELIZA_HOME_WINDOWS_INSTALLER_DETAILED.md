# Eliza Home Windows Installer: Detailed Implementation Record

## Scope and Goal

This document explains, in detail, what had to be done to get a reliable Windows installer and release flow for Eliza Home (Electrobun) in `dutchiono/eliza-home`.

Primary objective:

- Produce a Windows installer that installs consistently.
- Ensure the installed app launches and backend becomes reachable.
- Make GitHub Actions reliably publish a single canonical Windows installer asset as part of the same CI/release flow used by other platforms.

Secondary objective:

- Remove workflow flakiness and false negatives that were blocking releases even when the app itself was healthy.

---

## Repository Context

Eliza Home desktop packaging now lives in:

- `packages/home/electrobun`

Runtime and shared code are split (important for dependency resolution):

- `packages/autonomous` (agent/runtime APIs and backend path)
- `packages/app-core` (shared interfaces/components)

This split mattered because earlier Windows packaging logic still assumed older module/layout behavior and could pass in dev while failing in packaged runtime.

---

## What Was Failing Initially

### 1. Installer/launcher contract was not deterministic on Windows

Symptoms:

- Installer appeared to run but app location/launch path was unclear.
- Launcher behavior differed between extraction/runtime contexts.
- Smoke checks were tied to transient extraction paths.

Root causes:

- No hard installed-path contract for smoke validation.
- Assumptions around self-extraction paths instead of installed paths.
- Windows path depth and timing issues causing brittle checks.

### 2. Windows smoke was producing false failures

Symptoms:

- Backend started (`/api/auth/status` healthy), but smoke still failed.

Root causes:

- Startup log matching was too broad (`Cannot find module` treated as fatal unconditionally).
- Optional plugin warnings (for example, missing optional provider plugins) were interpreted as fatal startup failures.
- Stale startup log content could be re-read and misclassified.

### 3. Release asset validation failed after matrix lanes passed

Symptoms:

- All matrix lanes green, then `Create Release` failed.
- Error: expected one canonical Windows setup zip, found two.

Root causes:

- Artifact collection matched too-broad zip patterns.
- Both `...Setup...zip` and `...Setup...exe.zip` ended up in release file collection.

### 4. Pipeline intermittently failed early on frozen lockfile

Symptoms:

- `Validate Release Inputs` failed at `bun install --frozen-lockfile`.

Root causes:

- `bun.lock` drift relative to committed workspace state.
- CI release gates enforced frozen lockfile (correctly), exposing lockfile updates not yet committed.

---

## Design Decisions That Unblocked Windows

## 1. Treat Windows install as a contract, not a side effect

The reliable contract used by smoke and release is:

- Installer executes.
- Install root exists.
- Installed launcher exists.
- Start Menu shortcut exists.
- Backend health endpoint becomes reachable in timeout window.

If these are true, Windows pass criteria are met.

## 2. Keep preflight/layout checks as diagnostics where appropriate

Preflight still captures useful debugging information, but backend health + launcher liveness are the hard gates.

## 3. Canonical Windows public asset policy

Only one public canonical Windows setup zip should survive release collection:

- `*win*x64*Setup*.exe.zip`

This prevents downstream confusion and release validation ambiguity.

## 4. Windows close behavior should match user expectation

On Windows, closing the main window now defaults to full app quit (not hidden auto-reopen behavior). Tray behavior is still configurable via env, but the default is standard Windows UX.

---

## Concrete Changes Applied

## A. Windows smoke hardening

File:

- `packages/home/electrobun/scripts/smoke-test-windows.ps1`

Changes:

- Added fatal-line classifier logic instead of blanket `Cannot find module` matching.
- Optional plugin-missing warnings no longer automatically fail startup.
- Startup log is reset before launch to avoid stale-log false failures.
- Failure remains strict for true fatal signals (`Failed to start`, child process exits, unhandled runtime failures, etc.).

Result:

- Windows smoke now fails for real startup breakage, not optional plugin warnings.

## B. Canonical Windows release asset enforcement

Files:

- `.github/workflows/ci.yaml`
- `.github/workflows/release-home-electrobun.yml`

Changes:

- Windows zip retention narrowed to canonical pattern:
  - keep `*win*x64*Setup*.exe.zip`
  - remove other setup zip variants during packaging stage.
- Public release collection now selects canonical setup zip only.
- Windows release validation now checks canonical setup zip only.

Result:

- `Create Release` no longer fails due to duplicate setup zip candidates.

## C. Lockfile gate stabilization

File:

- `bun.lock`

Changes:

- Re-generated and committed whenever CI showed frozen lockfile drift.

Result:

- `Validate Release Inputs` can pass frozen install checks predictably.

## D. Windows app close behavior normalization

File:

- `packages/home/electrobun/src/index.ts`

Changes:

- Added close behavior resolver with Windows default = `quit`.
- On window close (Windows default path), app sets quit state and exits rather than respawning minimized background window.
- Added env override for alternative behavior:
  - `MILADY_WINDOW_CLOSE_BEHAVIOR=tray` for tray-style persistence
  - `MILADY_WINDOW_CLOSE_BEHAVIOR=quit` for explicit exit behavior

Result:

- Closing app window now behaves like standard Windows desktop apps by default.

---

## CI/Release Topology That Was Preserved

The flow remains chained and operator-visible:

1. CI gates (`lint-and-format`, `test`, `build`)
2. `Tests / All Tests Passed`
3. `Prepare Release`
4. `Validate Release Inputs`
5. Matrix `Build & Release` lanes:
   - Windows x64
   - Linux x64
   - macOS Intel
   - macOS Apple Silicon
6. `Create Release`

No extra mystery workflow is required for normal release progression.

---

## Why Windows Was Harder Than Other Lanes

Windows had compounded reliability issues:

- Path-length and staging-depth sensitivity.
- Installer/extraction model differences versus macOS/Linux app bundles.
- Optional plugin/module resolution warnings that are harmless at runtime but noisy in logs.
- CI artifact naming overlap that allowed multiple setup zips to pass into release collection.
- Strict frozen lockfile checks in release gates.

Other lanes were mostly packaging consistency problems; Windows also needed installer contract clarity and smoke classifier hardening.

---

## Operational Playbook for Future Changes

When touching Windows release flow, always verify in this order:

1. `Validate Release Inputs` passes frozen lockfile check.
2. Windows matrix lane passes:
   - package
   - wrapper installer build
   - smoke (launcher + backend health)
3. `Create Release` passes canonical asset validation.
4. Release page contains exactly one public Windows setup zip asset pattern.

If Windows fails but backend is healthy:

- Inspect startup log classification logic first (false-fail risk).

If `Create Release` fails after matrix green:

- Inspect release file collection globs and canonical asset filtering first.

If release fails early at dependency install:

- Refresh and commit `bun.lock`, then rerun.

---

## Known Remaining Quality Work (Not Blocking Installer)

- Broader plugin optionality policy and diagnostics consistency.
- Improved UX around tray/close settings exposure in app settings (currently env-driven behavior is available for advanced users).
- More explicit release smoke diagnostics aggregation in one summary artifact for operators.

These are quality improvements, not critical blockers for current Windows installer reliability.

---

## Summary

The Windows installer became reliable only after treating install/launch as an explicit contract and tightening both smoke and release asset logic around that contract.

Key wins:

- Windows smoke now validates real app health.
- Release flow now enforces one canonical Windows installer asset.
- Frozen lockfile gate is handled correctly.
- Default Windows close behavior now matches user expectation (close exits).

This is the baseline required to keep Eliza Home Windows delivery stable while continuing feature work.
