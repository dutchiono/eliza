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
$iconPath = Join-Path $PSScriptRoot "..\assets\appIcon.ico"

$tempRoot = Join-Path $env:TEMP ("eliza-home-wrapper-installer-" + [Guid]::NewGuid().ToString("N"))
$payloadRoot = Join-Path $tempRoot "payload"
$payloadAppRoot = Join-Path $payloadRoot "app"
$issPath = Join-Path $tempRoot "eliza-home-installer.iss"
$manifestPath = Join-Path $resolvedArtifactsDir "windows-installer-contract.json"
$innoCompiler = @(
  $env:INNO_SETUP_ISCC,
  (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
  (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) } | Select-Object -First 1

try {
  if (-not $innoCompiler) {
    throw "Could not find Inno Setup compiler (ISCC.exe)."
  }

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

  $contract = Get-ElizaHomeWindowsInstallContract -BuildEnv $BuildEnv
  $appDirectoryName = Split-Path -Leaf $contract.AppRoot
  $defaultDirName = $contract.AppRoot.Replace('\', '\\')
  $groupName = (Split-Path -Parent $contract.ShortcutPath).Replace("$($env:APPDATA)\Microsoft\Windows\Start Menu\Programs\", "")
  $groupName = $groupName -replace '\\', '\'
  $shortcutName = [System.IO.Path]::GetFileNameWithoutExtension($contract.ShortcutName)
  $launcherRelative = "bin\launcher.exe"
  $workingDirRelative = "bin"
  $outputDirEscaped = $resolvedArtifactsDir.Replace('\', '\\')
  $payloadSourceEscaped = $payloadAppRoot.Replace('\', '\\')
  $iconDirective = if (Test-Path $iconPath) {
    "SetupIconFile=$($iconPath.Replace('\', '\\'))"
  } else {
    ""
  }

  $issContents = @"
[Setup]
AppId=ai.eliza.home.$($contract.Channel)
AppName=$AppName
AppVersion=$Version
AppPublisher=elizaOS
DefaultDirName=$defaultDirName
DefaultGroupName=$groupName
OutputDir=$outputDirEscaped
OutputBaseFilename=$assetBaseName
Compression=lzma2/ultra64
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableDirPage=yes
DisableProgramGroupPage=yes
WizardStyle=modern
UninstallDisplayIcon={app}\$launcherRelative
$iconDirective

[Files]
Source: "$payloadSourceEscaped\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\\$groupName\\$shortcutName"; Filename: "{app}\\$launcherRelative"; WorkingDir: "{app}\\$workingDirRelative"
"@
  Set-Content -Path $issPath -Value $issContents -Encoding Ascii

  & $innoCompiler "/Qp" $issPath | Out-Null
  if (-not (Test-Path $outputExe)) {
    throw "Wrapper installer was not generated at $outputExe"
  }

  [ordered]@{
    appName = $AppName
    version = $Version
    channel = $contract.Channel
    installerType = "inno-setup"
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
