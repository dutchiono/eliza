param(
  [string]$ArtifactsDir = (Join-Path $PSScriptRoot "..\\artifacts"),
  [string]$BuildDir = (Join-Path $PSScriptRoot "..\\build"),
  [string]$BuildEnv = "canary",
  [int]$BackendPort = 2138,
  [int]$TimeoutSeconds = 240,
  [int]$InstallTimeoutSeconds = 600,
  [switch]$PreferInstaller
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "windows-installer-common.ps1")

$smokeEventLogFile = $env:MILADY_TEST_WINDOWS_SMOKE_LOG_FILE

function Write-SmokeEvent([string]$Type, [hashtable]$Data = @{}) {
  $payload = [ordered]@{
    timestamp = (Get-Date).ToString("o")
    type = $Type
  }
  foreach ($entry in $Data.GetEnumerator()) {
    $payload[$entry.Key] = $entry.Value
  }
  $json = $payload | ConvertTo-Json -Compress -Depth 8
  Write-Host ("[smoke] " + $json)
  if (-not [string]::IsNullOrWhiteSpace($smokeEventLogFile)) {
    $logParent = Split-Path -Parent $smokeEventLogFile
    if (-not [string]::IsNullOrWhiteSpace($logParent)) {
      New-Item -ItemType Directory -Force -Path $logParent | Out-Null
    }
    Add-Content -Path $smokeEventLogFile -Value $json -Encoding utf8
  }
}

function Get-CanonicalPath([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }
  try {
    return [System.IO.Path]::GetFullPath($Value)
  } catch {
    return $Value
  }
}

function Write-PathDiagnostics([string]$Label, [string]$PathValue) {
  $resolvedPath = Get-CanonicalPath $PathValue
  if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
    return
  }

  $pathLength = $resolvedPath.Length
  $riskLevel = if ($pathLength -ge 250) {
    "high"
  } elseif ($pathLength -ge 220) {
    "warning"
  } else {
    "ok"
  }

  Write-SmokeEvent "path.diagnostic" @{
    label = $Label
    path = $resolvedPath
    length = $pathLength
    risk = $riskLevel
  }
}

function Find-InstallerExecutable([string]$ResolvedArtifactsDir, [string]$TemporaryRoot) {
  $installer = Get-ChildItem -Path $ResolvedArtifactsDir -File -Filter "*Setup*.exe" -ErrorAction SilentlyContinue |
    Sort-Object Length -Descending |
    Select-Object -First 1
  if ($installer) {
    return $installer
  }

  $installerZip = Get-ChildItem -Path $ResolvedArtifactsDir -File -Filter "*Setup*.zip" -ErrorAction SilentlyContinue |
    Sort-Object Length -Descending |
    Select-Object -First 1
  if (-not $installerZip) {
    return $null
  }

  Write-PathDiagnostics -Label "installer_zip" -PathValue $installerZip.FullName
  New-Item -ItemType Directory -Force -Path $TemporaryRoot | Out-Null
  Expand-Archive -Path $installerZip.FullName -DestinationPath $TemporaryRoot -Force
  return Get-ChildItem -Path $TemporaryRoot -Recurse -File -Filter "*Setup*.exe" -ErrorAction SilentlyContinue |
    Sort-Object Length -Descending |
    Select-Object -First 1
}

function Stop-ElizaHomeProcesses() {
  Get-Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.ProcessName -in @("launcher", "bun") -or
      $_.ProcessName -like "Eliza*" -or
      $_.ProcessName -like "*Setup*"
    } |
    Stop-Process -Force
}

function Get-ObservedBackendPorts([int]$DefaultPort, [string]$StartupLog) {
  $ports = [System.Collections.Generic.List[int]]::new()
  $ports.Add($DefaultPort)

  if (Test-Path $StartupLog) {
    $logLines = Get-Content $StartupLog -Tail 200 -ErrorAction SilentlyContinue
    foreach ($line in $logLines) {
      if (
        $line -match 'Runtime started -- agent: .* port: ([0-9]+), pid:' -or
        $line -match 'Server bound to dynamic port ([0-9]+)' -or
        $line -match 'Waiting for health endpoint at http://127\.0\.0\.1:([0-9]+)/api/health'
      ) {
        $observedPort = [int]$Matches[1]
        if (-not $ports.Contains($observedPort)) {
          $ports.Add($observedPort)
        }
      }
    }
  }

  $fallbackStart = [Math]::Max(1024, $DefaultPort - 2)
  $fallbackEnd = $DefaultPort + 24
  for ($candidate = $fallbackStart; $candidate -le $fallbackEnd; $candidate++) {
    if (-not $ports.Contains($candidate)) {
      $ports.Add($candidate)
    }
  }

  try {
    $candidatePids = Get-Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.ProcessName -in @("launcher", "bun") -or
        $_.ProcessName -like "Eliza*"
      } |
      Select-Object -ExpandProperty Id
    if ($candidatePids) {
      $listening = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $candidatePids -contains $_.OwningProcess } |
        Select-Object -ExpandProperty LocalPort -Unique
      foreach ($port in $listening) {
        if ($port -is [int] -and -not $ports.Contains($port)) {
          $ports.Add($port)
        }
      }
    }
  } catch {
    # Ignore socket enumeration failures in CI.
  }

  return $ports.ToArray()
}

$resolvedArtifactsDir = (Resolve-Path $ArtifactsDir).Path
$resolvedBuildDir = $null
try {
  $resolvedBuildDir = (Resolve-Path $BuildDir).Path
} catch {
  $resolvedBuildDir = $null
}

$contract = Get-ElizaHomeWindowsInstallContract -BuildEnv $BuildEnv
$startupLog = Join-Path $env:APPDATA "Eliza Home\\eliza-home-startup.log"
$smokeTempRoot = if ([string]::IsNullOrWhiteSpace($env:MILADY_TEST_WINDOWS_SMOKE_TEMP_ROOT)) {
  if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:TEMP } else { $env:RUNNER_TEMP }
} else {
  $env:MILADY_TEST_WINDOWS_SMOKE_TEMP_ROOT
}
$smokeTempRoot = Get-CanonicalPath $smokeTempRoot
$tempExtractDir = Join-Path $smokeTempRoot ("ehs-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
$probeAttempts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

Write-SmokeEvent "smoke.contract" @{
  installerRequired = [bool]$PreferInstaller
  backendHealthRequired = $true
  launcherLivenessRequired = $true
  installedPathRequired = $true
  shortcutRequired = $true
  preflightFatal = $false
}
Write-PathDiagnostics -Label "artifacts_dir" -PathValue $resolvedArtifactsDir
if ($resolvedBuildDir) {
  Write-PathDiagnostics -Label "build_dir" -PathValue $resolvedBuildDir
}
Write-PathDiagnostics -Label "smoke_temp_root" -PathValue $smokeTempRoot
Write-PathDiagnostics -Label "install_root" -PathValue $contract.InstallRoot
Write-PathDiagnostics -Label "launcher_path" -PathValue $contract.LauncherPath
Write-PathDiagnostics -Label "runtime_root" -PathValue $contract.RuntimeRoot
Write-PathDiagnostics -Label "shortcut_path" -PathValue $contract.ShortcutPath
Write-PathDiagnostics -Label "startup_log" -PathValue $startupLog

Stop-ElizaHomeProcesses
Remove-ElizaHomeInstalledContract -Contract $contract
$env:ELECTROBUN_CONSOLE = "1"

$installer = Find-InstallerExecutable -ResolvedArtifactsDir $resolvedArtifactsDir -TemporaryRoot $tempExtractDir
if (-not $installer) {
  throw "No Windows installer executable found in $resolvedArtifactsDir"
}
Write-PathDiagnostics -Label "installer_exe" -PathValue $installer.FullName

Write-SmokeEvent "preflight.inventory" @{
  hasInstaller = $true
  installRootExistsBeforeRun = [bool](Test-Path $contract.InstallRoot)
  launcherExistsBeforeRun = [bool](Test-Path $contract.LauncherPath)
  shortcutExistsBeforeRun = [bool](Test-Path $contract.ShortcutPath)
}

$installerLogPath = Join-Path $smokeTempRoot "installer.log"
$installerArgs = if ($PreferInstaller) {
  @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", "/LOG=`"$installerLogPath`"")
} else {
  @()
}
Write-SmokeEvent "installer.start" @{
  path = $installer.FullName
  arguments = $installerArgs
}
$installerProcess = Start-Process -FilePath $installer.FullName -ArgumentList $installerArgs -WorkingDirectory (Split-Path -Parent $installer.FullName) -PassThru

$installDeadline = (Get-Date).AddSeconds($InstallTimeoutSeconds)
$installRootReady = $false
$shortcutReady = $false
$launcherReady = $false
$lastInstallerProgressLog = Get-Date

while ((Get-Date) -lt $installDeadline) {
  $installRootReady = Test-Path $contract.InstallRoot
  $launcherReady = Test-Path $contract.LauncherPath
  $shortcutReady = Test-Path $contract.ShortcutPath

  if ($installRootReady -and $launcherReady -and $shortcutReady) {
    break
  }

  if ($installerProcess.HasExited -and $installerProcess.ExitCode -ne 0) {
    Write-SmokeEvent "installer.exit" @{
      code = $installerProcess.ExitCode
      warning = $false
    }
    break
  }

  if (((Get-Date) - $lastInstallerProgressLog).TotalSeconds -ge 30) {
    $installerLogTail = $null
    if (Test-Path $installerLogPath) {
      $installerLogTail = (Get-Content $installerLogPath -Tail 5 -ErrorAction SilentlyContinue) -join " | "
    }
    Write-SmokeEvent "installer.wait" @{
      installerStillRunning = -not $installerProcess.HasExited
      installRootReady = $installRootReady
      launcherReady = $launcherReady
      shortcutReady = $shortcutReady
      installRoot = $contract.InstallRoot
      installerLogTail = $installerLogTail
    }
    $lastInstallerProgressLog = Get-Date
  }

  Start-Sleep -Seconds 2
}

if (-not $installRootReady) {
  Write-SmokeEvent "contract.failure" @{
    reason = if ($installerProcess.HasExited) { "install-root-missing" } else { "install-timeout" }
    installRoot = $contract.InstallRoot
    installerExitCode = if ($installerProcess.HasExited) { $installerProcess.ExitCode } else { $null }
  }
  throw "Windows installer did not produce install root within $InstallTimeoutSeconds seconds: $($contract.InstallRoot)"
}

if (-not $launcherReady) {
  Write-SmokeEvent "contract.failure" @{
    reason = "launcher-missing"
    launcherPath = $contract.LauncherPath
    installerExitCode = if ($installerProcess.HasExited) { $installerProcess.ExitCode } else { $null }
  }
  throw "Installed launcher was not created: $($contract.LauncherPath)"
}

if (-not $shortcutReady) {
  Write-SmokeEvent "contract.failure" @{
    reason = "shortcut-missing"
    shortcutPath = $contract.ShortcutPath
    installerExitCode = if ($installerProcess.HasExited) { $installerProcess.ExitCode } else { $null }
  }
  throw "Installed Start Menu shortcut was not created: $($contract.ShortcutPath)"
}

if (-not (Test-Path $contract.RuntimeRoot)) {
  Write-SmokeEvent "runtime.warning" @{
    runtimeRoot = $contract.RuntimeRoot
    reason = "runtime-root-missing-before-launch"
  }
}

$launcherProcess = Start-Process -FilePath $contract.LauncherPath -WorkingDirectory (Split-Path -Parent $contract.LauncherPath) -PassThru
Write-SmokeEvent "launcher.start" @{
  path = $contract.LauncherPath
  source = "installed-launcher"
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$healthy = $false
$launcherSeenRunning = $false

try {
  while ((Get-Date) -lt $deadline) {
    if (Get-Process -Name "launcher" -ErrorAction SilentlyContinue) {
      $launcherSeenRunning = $true
    }

    if (Test-Path $startupLog) {
      $recentLog = Get-Content $startupLog -Tail 200 -ErrorAction SilentlyContinue
      if ($recentLog -match 'Cannot find module|Child process exited with code|Failed to start:') {
        Write-Host "Recent startup log:"
        $recentLog
        Write-SmokeEvent "contract.failure" @{
          reason = "backend-startup-error"
        }
        throw "Windows packaged app reported a startup failure."
      }
    }

    foreach ($port in Get-ObservedBackendPorts -DefaultPort $BackendPort -StartupLog $startupLog) {
      foreach ($path in @("/api/health", "/api/auth/status")) {
        $probeAttempts.Add("$port$path") | Out-Null
        try {
          $response = Invoke-WebRequest -Uri "http://127.0.0.1:$port$path" -UseBasicParsing -TimeoutSec 2
          if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            $healthy = $true
            Write-SmokeEvent "endpoint.healthy" @{ port = $port; path = $path; status = $response.StatusCode }
            break
          }
        } catch {
          # Continue probing.
        }
      }

      if ($healthy) {
        break
      }
    }

    if ($healthy) {
      break
    }

    Start-Sleep -Seconds 2
  }

  if (-not $healthy) {
    Write-SmokeEvent "endpoint.probe-matrix" @{
      attempts = @($probeAttempts | Sort-Object)
      totalAttempts = $probeAttempts.Count
    }
    Write-SmokeEvent "contract.failure" @{
      reason = "backend-timeout"
      installRoot = $contract.InstallRoot
      launcherPath = $contract.LauncherPath
      shortcutPath = $contract.ShortcutPath
    }
    throw "Windows packaged app did not become healthy within $TimeoutSeconds seconds."
  }

  if (-not $launcherSeenRunning) {
    Write-SmokeEvent "contract.failure" @{
      reason = "launcher-never-ran"
      launcherPath = $contract.LauncherPath
    }
    throw "Windows packaged app became healthy but launcher process was not observed."
  }

  Write-SmokeEvent "endpoint.probe-matrix" @{
    attempts = @($probeAttempts | Sort-Object)
    totalAttempts = $probeAttempts.Count
  }
  Write-SmokeEvent "contract.pass" @{
    launcherObserved = $launcherSeenRunning
    backendHealthy = $healthy
    launcherPath = $contract.LauncherPath
    shortcutPath = $contract.ShortcutPath
    installRoot = $contract.InstallRoot
  }
} finally {
  Stop-ElizaHomeProcesses
  if (Test-Path $tempExtractDir) {
    Remove-Item -Path $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
