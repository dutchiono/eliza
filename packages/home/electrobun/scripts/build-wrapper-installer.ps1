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
$manifestPath = Join-Path $resolvedArtifactsDir "windows-installer-contract.json"
$issOutputPath = Join-Path $resolvedArtifactsDir "windows-installer.iss"
$compilerLogPath = Join-Path $resolvedArtifactsDir "windows-installer-build.log"
$tempRoot = New-ElizaHomeWindowsShortTempRoot -Prefix "ehw"
$payloadRoot = Join-Path $tempRoot "p"
$payloadAppRoot = Join-Path $payloadRoot "app"
$issPath = Join-Path $tempRoot "wrapper.iss"
$innoCompiler = @(
  $env:INNO_SETUP_ISCC,
  (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
  (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) } | Select-Object -First 1
$contract = Get-ElizaHomeWindowsInstallContract -BuildEnv $BuildEnv
$manifest = [ordered]@{
  appName = $AppName
  version = $Version
  channel = $contract.Channel
  installerType = "inno-setup"
  payloadSourceLayer = $payloadSource.SourceLayer
  payloadSourcePath = $payloadSource.Path
  stagingRoot = $tempRoot
  stagedAppRoot = $payloadAppRoot
  stagedLauncherPath = $null
  stagedRuntimeRoot = $null
  installerPath = $outputExe
  installRoot = $contract.InstallRoot
  launcherPath = $contract.LauncherPath
  runtimeRoot = $contract.RuntimeRoot
  shortcutPath = $contract.ShortcutPath
  expectedInstallRoot = $contract.InstallRoot
  expectedLauncherPath = $contract.LauncherPath
  expectedRuntimeRoot = $contract.RuntimeRoot
  expectedShortcutPath = $contract.ShortcutPath
  generatedIssPath = $issOutputPath
  compilerLogPath = $compilerLogPath
  generatedAt = (Get-Date).ToString("o")
}

try {
  $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding utf8

  if (-not $innoCompiler) {
    $manifest.validationStatus = "failed"
    $manifest.validationErrors = @("missing-inno-compiler")
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding utf8
    throw "Could not find Inno Setup compiler (ISCC.exe)."
  }

  Remove-Item -Path $outputExe -Force -ErrorAction SilentlyContinue
  Remove-Item -Path $issOutputPath -Force -ErrorAction SilentlyContinue
  Remove-Item -Path $compilerLogPath -Force -ErrorAction SilentlyContinue

  New-Item -ItemType Directory -Force -Path $payloadRoot | Out-Null
  if ($payloadSource.SourceLayer -eq "packaged_archive") {
    $archiveExtractRoot = Join-Path $tempRoot "x"
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

  $inspection = Get-ElizaHomeWindowsPayloadInspection -AppRoot $payloadAppRoot
  $manifest.stagedAppRoot = $inspection.appRoot
  $manifest.stagedLauncherPath = $inspection.launcherPath
  $manifest.stagedRuntimeRoot = $inspection.runtimeRoot
  $manifest.payloadInspection = [ordered]@{
    launcherExists = $inspection.launcherExists
    runtimeExists = $inspection.runtimeExists
    runtimeRootCandidates = $inspection.runtimeRootCandidates
    iconPath = $inspection.iconPath
    iconCandidates = $inspection.iconCandidates
  }
  $installedLayout = Get-ElizaHomeInstalledPathLayoutDiagnostic -PayloadAppRoot $inspection.appRoot -InstallRoot $contract.InstallRoot
  $manifest.installLayout = [ordered]@{
    fileCount = $installedLayout.fileCount
    maxAllowedLength = $installedLayout.maxAllowedLength
    maxInstalledLength = $installedLayout.maxInstalledLength
    maxInstalledPath = $installedLayout.maxInstalledPath
    maxRelativePath = $installedLayout.maxRelativePath
    withinLimit = $installedLayout.withinLimit
    overflow = $installedLayout.overflow
  }
  $manifest.pathDiagnostics = [ordered]@{
    payloadSource = Get-ElizaHomePathDiagnostic $payloadSource.Path
    stagingRoot = Get-ElizaHomePathDiagnostic $tempRoot
    stagedAppRoot = Get-ElizaHomePathDiagnostic $inspection.appRoot
    stagedLauncherPath = Get-ElizaHomePathDiagnostic $inspection.launcherPath
    stagedRuntimeRoot = Get-ElizaHomePathDiagnostic $inspection.runtimeRoot
    outputExe = Get-ElizaHomePathDiagnostic $outputExe
    installRoot = Get-ElizaHomePathDiagnostic $contract.InstallRoot
    shortcutPath = Get-ElizaHomePathDiagnostic $contract.ShortcutPath
    longestInstalledPath = Get-ElizaHomePathDiagnostic $installedLayout.maxInstalledPath
  }

  $validationFailures = [System.Collections.Generic.List[string]]::new()
  if (-not $inspection.launcherExists) {
    $validationFailures.Add("staged-launcher-missing: $($inspection.launcherPath)")
  }
  if (-not $inspection.runtimeExists) {
    $candidateSummary = ($inspection.runtimeRootCandidates | ForEach-Object { $_ }) -join ", "
    $validationFailures.Add("staged-runtime-missing: $candidateSummary")
  }
  if (-not $installedLayout.withinLimit) {
    $validationFailures.Add("installed-path-too-long: $($installedLayout.maxInstalledLength) > $($installedLayout.maxAllowedLength) :: $($installedLayout.maxInstalledPath)")
  }

  $iconPath = $inspection.iconPath
  $defaultDirName = $contract.AppRoot.Replace('\', '\\')
  $groupName = (Split-Path -Parent $contract.ShortcutPath).Replace("$($env:APPDATA)\Microsoft\Windows\Start Menu\Programs\", "")
  $groupName = $groupName -replace '\\', '\'
  $shortcutName = [System.IO.Path]::GetFileNameWithoutExtension($contract.ShortcutName)
  $launcherRelative = "bin\launcher.exe"
  $workingDirRelative = "bin"
  $outputDirEscaped = $resolvedArtifactsDir.Replace('\', '\\')
  $payloadSourceEscaped = $inspection.appRoot.Replace('\', '\\')
  $iconDirective = if (-not [string]::IsNullOrWhiteSpace($iconPath) -and (Test-Path $iconPath)) {
    "SetupIconFile=$($iconPath.Replace('\', '\\'))"
  } else {
    ""
  }

  if ($validationFailures.Count -gt 0) {
    $manifest.validationStatus = "failed"
    $manifest.validationErrors = @($validationFailures)
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding utf8
    throw ($validationFailures -join "; ")
  }

  $manifest.validationStatus = "passed"
  $manifest.validationErrors = @()

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
  Set-Content -Path $issOutputPath -Value $issContents -Encoding Ascii
  $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding utf8

  $compilerOutput = (& $innoCompiler "/Qp" $issPath 2>&1) | Out-String
  Set-Content -Path $compilerLogPath -Value $compilerOutput -Encoding utf8
  if ($LASTEXITCODE -ne 0) {
    $manifest.validationStatus = "compiler_failed"
    $manifest.compilerFailure = "iss-source-path-invalid"
    $manifest.compilerExitCode = $LASTEXITCODE
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding utf8
    throw "Inno Setup compiler failed with exit code $LASTEXITCODE. See $compilerLogPath"
  }
  if (-not (Test-Path $outputExe)) {
    $manifest.validationStatus = "compiler_failed"
    $manifest.compilerFailure = "installer-output-missing"
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding utf8
    throw "Wrapper installer was not generated at $outputExe"
  }

  $manifest.validationStatus = "built"
  $manifest.generatedInstaller = $true
  $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding utf8

  Write-Host "Built Windows wrapper installer: $outputExe"
  Write-Host "Windows payload source ($($payloadSource.SourceLayer)): $($payloadSource.Path)"
  Write-Host "Expected install root: $($contract.InstallRoot)"
  Write-Host "Wrapper manifest: $manifestPath"
  Write-Host "Wrapper ISS: $issOutputPath"
  Write-Host "Wrapper compiler log: $compilerLogPath"
} finally {
  if (Test-Path $tempRoot) {
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
