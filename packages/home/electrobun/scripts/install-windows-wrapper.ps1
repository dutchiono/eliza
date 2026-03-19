param(
  [string]$BuildEnv = "canary",
  [string]$AppName = "Eliza Home",
  [string]$Version = "",
  [string]$PayloadZip = "payload.zip",
  [switch]$Quiet,
  [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "windows-installer-common.ps1")

$contract = Get-ElizaHomeWindowsInstallContract -BuildEnv $BuildEnv
$payloadPath = if ([System.IO.Path]::IsPathRooted($PayloadZip)) {
  $PayloadZip
} else {
  Join-Path $PSScriptRoot $PayloadZip
}

if (-not (Test-Path $payloadPath)) {
  throw "Payload zip not found: $payloadPath"
}

$stageRoot = Join-Path $env:TEMP ("eliza-home-install-" + [Guid]::NewGuid().ToString("N"))
$stageExtractDir = Join-Path $stageRoot "expanded"

try {
  New-Item -ItemType Directory -Force -Path $stageExtractDir | Out-Null
  & tar.exe -xf $payloadPath -C $stageExtractDir
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to extract payload archive: $payloadPath"
  }

  $payloadAppRoot = Join-Path $stageExtractDir "app"
  if (-not (Test-Path $payloadAppRoot)) {
    throw "Expanded payload is missing app/ root: $payloadAppRoot"
  }

  if (Test-Path $contract.AppRoot) {
    Remove-Item -Path $contract.AppRoot -Recurse -Force
  }

  New-Item -ItemType Directory -Force -Path $contract.InstallRoot | Out-Null
  Get-ChildItem -Path $payloadAppRoot -Force | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $contract.InstallRoot -Recurse -Force
  }

  if (-not (Test-Path $contract.LauncherPath)) {
    throw "Installed launcher missing after copy: $($contract.LauncherPath)"
  }

  if (-not (Test-Path $contract.RuntimeRoot)) {
    throw "Installed runtime root missing after copy: $($contract.RuntimeRoot)"
  }

  New-ElizaHomeStartMenuShortcut `
    -ShortcutPath $contract.ShortcutPath `
    -TargetPath $contract.LauncherPath `
    -WorkingDirectory (Split-Path -Parent $contract.LauncherPath) `
    -Description "Launch $AppName"

  $metadata = [ordered]@{
    appName = $AppName
    version = $Version
    channel = $contract.Channel
    installRoot = $contract.InstallRoot
    appRoot = $contract.AppRoot
    launcherPath = $contract.LauncherPath
    runtimeRoot = $contract.RuntimeRoot
    shortcutPath = $contract.ShortcutPath
    installedAt = (Get-Date).ToString("o")
  }
  $metadata | ConvertTo-Json -Depth 8 | Set-Content -Path $contract.MetadataPath -Encoding utf8

  if (-not $Quiet -and -not $NoLaunch) {
    Start-Process -FilePath $contract.LauncherPath -WorkingDirectory (Split-Path -Parent $contract.LauncherPath) | Out-Null
  }
} finally {
  if (Test-Path $stageRoot) {
    Remove-Item -Path $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
