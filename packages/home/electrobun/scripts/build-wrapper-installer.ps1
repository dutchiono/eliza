param(
  [string]$BuildDir = (Join-Path $PSScriptRoot "..\build"),
  [string]$ArtifactsDir = (Join-Path $PSScriptRoot "..\artifacts"),
  [string]$BuildEnv = "canary",
  [string]$AppName = "Eliza Home",
  [string]$Version = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "windows-installer-common.ps1")

$resolvedBuildDir = (Resolve-Path $BuildDir).Path
New-Item -ItemType Directory -Force -Path $ArtifactsDir | Out-Null
$resolvedArtifactsDir = (Resolve-Path $ArtifactsDir).Path

$payloadSource = Resolve-ElizaHomeWindowsPayloadSource -ArtifactsDir $resolvedArtifactsDir -BuildDir $resolvedBuildDir
$assetBaseName = Get-ElizaHomeWindowsAssetBaseName -BuildEnv $BuildEnv
$outputExe = Join-Path $resolvedArtifactsDir "$assetBaseName.exe"

$tempRoot = Join-Path $env:TEMP ("eliza-home-wrapper-installer-" + [Guid]::NewGuid().ToString("N"))
$payloadRoot = Join-Path $tempRoot "payload"
$payloadAppRoot = Join-Path $payloadRoot "app"
$payloadZip = Join-Path $tempRoot "payload.zip"
$installCmd = Join-Path $tempRoot "install.cmd"
$sedPath = Join-Path $tempRoot "installer.sed"
$manifestPath = Join-Path $resolvedArtifactsDir "windows-installer-contract.json"

try {
  New-Item -ItemType Directory -Force -Path $payloadRoot | Out-Null
  if ($payloadSource.SourceLayer -eq "packaged_archive") {
    $archiveExtractRoot = Join-Path $tempRoot "archive-expanded"
    New-Item -ItemType Directory -Force -Path $archiveExtractRoot | Out-Null
    & tar.exe --zstd -xf $payloadSource.Path -C $archiveExtractRoot
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to extract packaged Windows payload archive: $($payloadSource.Path)"
    }

    $archiveAppRoot = Get-ChildItem -Path $archiveExtractRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name |
      Select-Object -First 1
    if ($null -eq $archiveAppRoot) {
      throw "Packaged Windows payload archive did not contain a top-level app directory: $($payloadSource.Path)"
    }

    Move-Item -Path $archiveAppRoot.FullName -Destination $payloadAppRoot
  } else {
    New-Item -ItemType Directory -Force -Path $payloadAppRoot | Out-Null
    Get-ChildItem -Path $payloadSource.Path -Force | ForEach-Object {
      Copy-Item -Path $_.FullName -Destination $payloadAppRoot -Recurse -Force
    }
  }

  & tar.exe -a -cf $payloadZip -C $payloadRoot "app"
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $payloadZip)) {
    throw "Failed to create payload zip at $payloadZip"
  }

  $installCmdContents = @"
@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-windows-wrapper.ps1" -BuildEnv "$BuildEnv" -AppName "$AppName" -Version "$Version" -PayloadZip "%~dp0payload.zip" %*
exit /b %ERRORLEVEL%
"@
  Set-Content -Path $installCmd -Value $installCmdContents -Encoding Ascii

  $installScriptPath = Join-Path $PSScriptRoot "install-windows-wrapper.ps1"
  $commonScriptPath = Join-Path $PSScriptRoot "windows-installer-common.ps1"

  $sedContents = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=1
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$outputExe
FriendlyName=$AppName Setup
AppLaunched=cmd /c install.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=cmd /c install.cmd -Quiet -NoLaunch
UserQuietInstCmd=cmd /c install.cmd -Quiet -NoLaunch
SourceFiles=SourceFiles
[Strings]
FILE0="payload.zip"
FILE1="install.cmd"
FILE2="install-windows-wrapper.ps1"
FILE3="windows-installer-common.ps1"
[SourceFiles]
SourceFiles0=$tempRoot
[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
%FILE3%=
"@
  Set-Content -Path $sedPath -Value $sedContents -Encoding Ascii

  Copy-Item -Path $installScriptPath -Destination (Join-Path $tempRoot "install-windows-wrapper.ps1") -Force
  Copy-Item -Path $commonScriptPath -Destination (Join-Path $tempRoot "windows-installer-common.ps1") -Force

  & iexpress.exe /N $sedPath | Out-Null
  if (-not (Test-Path $outputExe)) {
    throw "Wrapper installer was not generated at $outputExe"
  }

  $contract = Get-ElizaHomeWindowsInstallContract -BuildEnv $BuildEnv
  [ordered]@{
    appName = $AppName
    version = $Version
    channel = $contract.Channel
    payloadSourceLayer = $payloadSource.SourceLayer
    payloadSourcePath = $payloadSource.Path
    installerPath = $outputExe
    installRoot = $contract.InstallRoot
    launcherPath = $contract.LauncherPath
    runtimeRoot = $contract.RuntimeRoot
    shortcutPath = $contract.ShortcutPath
    expectedInstallRoot = $contract.InstallRoot
    expectedLauncherPath = $contract.LauncherPath
    expectedRuntimeRoot = $contract.RuntimeRoot
    expectedShortcutPath = $contract.ShortcutPath
    generatedAt = (Get-Date).ToString("o")
  } | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding utf8

  Write-Host "Built Windows wrapper installer: $outputExe"
  Write-Host "Windows payload source ($($payloadSource.SourceLayer)): $($payloadSource.Path)"
  Write-Host "Expected install root: $($contract.InstallRoot)"
} finally {
  if (Test-Path $tempRoot) {
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
