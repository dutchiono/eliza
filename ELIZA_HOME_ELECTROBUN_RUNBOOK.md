# Eliza Home Electrobun Runbook

`packages/home` is the Eliza Home renderer app surface.

`packages/home/electrobun` is the desktop shell that packages:
- the `packages/home/dist` renderer bundle as `renderer/`
- the `packages/autonomous/dist` backend bundle as `home-dist/`
- the Electrobun preload bridge and native desktop assets

## Root scripts

Run from the repo root:

- `bun run desktop:home:stage`
  - Builds `packages/autonomous/dist`
  - Writes runtime build metadata
  - Copies runtime `node_modules` into `packages/autonomous/dist`
  - Builds `packages/home/dist`
  - Builds the Electrobun preload bridge
- `bun run desktop:home:package`
  - Runs Electrobun packaging for `packages/home/electrobun`
- `bun run desktop:home:build`
  - Runs `stage` then `package`
- `bun run desktop:home:run`
  - Runs `build` then launches the packaged app locally

## GitHub workflow

Workflow:
- `.github/workflows/release-home-electrobun.yml`

Responsibilities:
- derive release tag/version/channel
- align `packages/home` and `packages/home/electrobun` versions
- stage desktop inputs with `scripts/home-desktop-build.mjs`
- package Electrobun artifacts for Windows, macOS Intel, macOS Apple Silicon, and Linux
- run packaged smoke checks
- upload build artifacts
- publish public installers to a GitHub Release

## Expected artifacts

Artifacts are written under:
- `packages/home/electrobun/artifacts`

Typical outputs:
- Windows setup bundle: `*Setup*.zip`
- Windows updater files: `*.tar.zst`, `*-update.json`, `*.patch`
- macOS installers: `*.dmg`
- Linux archive: `*.tar.gz`

The GitHub Release publishes end-user installables only. Updater transport files stay in workflow artifacts.

## Windows caveats

- Root installs should use `bun install --ignore-scripts` in CI to avoid unrelated native postinstall failures during packaging.
- Electrobun on Windows may need:
  - `rcedit` seeded into the local Electrobun package
  - the native Electrobun CLI pre-extracted before packaging
- Packaged smoke logs are written to:
  - `%APPDATA%\\Eliza Home\\eliza-home-startup.log`
- Self-extracted Windows launcher content lives under:
  - `%LOCALAPPDATA%\\ai.eliza.home\\canary\\self-extraction`

## Contract to preserve

Do not point the Home desktop shell back at `apps/app` or Milady paths.

The intended contract is:
- renderer input: `packages/home`
- backend input: `packages/autonomous/dist/bin.js`
- desktop shell: `packages/home/electrobun`
