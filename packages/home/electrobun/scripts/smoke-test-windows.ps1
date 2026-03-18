param(
  [string]$ArtifactsDir = (Join-Path $PSScriptRoot "..\\artifacts"),
  [string]$BuildDir = (Join-Path $PSScriptRoot "..\\build"),
  [int]$BackendPort = 2138,
  [int]$TimeoutSeconds = 240,
  [switch]$PreferInstaller
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
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

$resolvedArtifactsDir = (Resolve-Path $ArtifactsDir).Path
$resolvedBuildDir = $null
try {
  $resolvedBuildDir = (Resolve-Path $BuildDir).Path
} catch {
  $resolvedBuildDir = $null
}
# Eliza Home writes its startup log to AppData\Roaming\Eliza Home on Windows, not the
# Unix-style ~/.config/Eliza Home path used on macOS/Linux.
$startupLog = Join-Path $env:APPDATA "Eliza Home\\eliza-home-startup.log"
$selfExtractionRoot = Join-Path $env:LOCALAPPDATA "ai.eliza.home\\canary\\self-extraction"
$smokeTempRoot = if ([string]::IsNullOrWhiteSpace($env:MILADY_TEST_WINDOWS_SMOKE_TEMP_ROOT)) {
  if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:TEMP } else { $env:RUNNER_TEMP }
} else {
  $env:MILADY_TEST_WINDOWS_SMOKE_TEMP_ROOT
}
$smokeTempRoot = Get-CanonicalPath $smokeTempRoot
$tempExtractDir = Join-Path $smokeTempRoot ("ehs-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
$persistLauncherDir = $env:MILADY_TEST_WINDOWS_LAUNCHER_DIR
$persistLauncherPathFile = $env:MILADY_TEST_WINDOWS_LAUNCHER_PATH_FILE
$script:runtimeRootCandidatesTried = [System.Collections.Generic.List[string]]::new()
$probeAttempts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
function Get-StagedLauncherFromPathFile([string]$PathFile) {
  if ([string]::IsNullOrWhiteSpace($PathFile) -or -not (Test-Path $PathFile)) {
    return $null
  }

  try {
    $candidate = (Get-Content -Path $PathFile -ErrorAction Stop | Select-Object -First 1).Trim()
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
      return Get-Item $candidate
    }
  } catch {
    Write-Warning "Failed to read persisted launcher path file ($PathFile): $($_.Exception.Message)"
  }

  return $null
}

function Find-Launcher([string]$Root) {
  if (-not (Test-Path $Root)) {
    return $null
  }

  return Get-ChildItem -Path $Root -Recurse -File -Filter "launcher.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName |
    Select-Object -First 1
}

function Expand-PackagedTarball([string]$ArchivePath, [string]$DestinationPath) {
  $tarCommand = if (Test-Path "C:\\Windows\\System32\\tar.exe") {
    "C:\\Windows\\System32\\tar.exe"
  } else {
    "tar"
  }

  New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null
  & $tarCommand -xf $ArchivePath -C $DestinationPath
}

function Resolve-RuntimeRootFromLauncher([System.IO.FileInfo]$Launcher) {
  if (-not $Launcher) {
    return $null
  }

  $launcherDir = Split-Path -Parent $Launcher.FullName
  $appRoot = Split-Path -Parent $launcherDir
  $candidates = @(
    (Join-Path $appRoot "home-dist"),
    (Join-Path $appRoot "resources\\app\\home-dist"),
    (Join-Path $launcherDir "..\\resources\\app\\home-dist")
  )

  foreach ($candidate in $candidates) {
    $resolved = $null
    try {
      $resolved = [System.IO.Path]::GetFullPath($candidate)
    } catch {
      $resolved = $candidate
    }
    if (-not [string]::IsNullOrWhiteSpace($resolved) -and -not $script:runtimeRootCandidatesTried.Contains($resolved)) {
      $script:runtimeRootCandidatesTried.Add($resolved) | Out-Null
    }

    if (Test-Path $resolved) {
      return $resolved
    }
  }

  return $null
}

function Test-PackagedRuntimeSurface([string]$RuntimeRoot) {
  if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    throw "Runtime root is empty."
  }

  if (-not (Test-Path $RuntimeRoot)) {
    throw "Runtime root does not exist: $RuntimeRoot"
  }

  $entryCandidates = @(
    (Join-Path $RuntimeRoot "bin.js"),
    (Join-Path $RuntimeRoot "entry.js"),
    (Join-Path $RuntimeRoot "dist\\bin.js"),
    (Join-Path $RuntimeRoot "dist\\entry.js"),
    (Join-Path $RuntimeRoot "packages\\autonomous\\src\\bin.js"),
    (Join-Path $RuntimeRoot "packages\\autonomous\\bin.js"),
    (Join-Path $RuntimeRoot "packages\\autonomous\\dist\\bin.js"),
    (Join-Path $RuntimeRoot "packages\\autonomous\\dist\\entry.js"),
    (Join-Path $RuntimeRoot "packages\\autonomous\\build\\bin.js")
  )
  $runtimeEntry = $entryCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $runtimeEntry) {
    Write-Warning "No runtime entrypoint found in $RuntimeRoot (checked bin.js, entry.js, dist/bin.js, dist/entry.js, packages/autonomous/src/bin.js, packages/autonomous/bin.js, packages/autonomous/dist/bin.js, packages/autonomous/dist/entry.js, packages/autonomous/build/bin.js). Continuing with backend liveness validation."
    return
  }

  $requiredPaths = @(
    (Join-Path $RuntimeRoot "node_modules\\@elizaos\\core\\package.json"),
    (Join-Path $RuntimeRoot "node_modules\\@elizaos\\core\\dist\\node\\index.node.js")
  )
  foreach ($requiredPath in $requiredPaths) {
    if (-not (Test-Path $requiredPath)) {
      Write-Warning "Missing required packaged runtime dependency preflight path: $requiredPath"
    }
  }

  $resolveScript = @'
const { createRequire } = require("node:module");
const path = require("node:path");
const runtimeRoot = process.argv[1];
const req = createRequire(path.join(runtimeRoot, "package.json"));
for (const moduleName of ["@elizaos/core", "@elizaos/core/package.json"]) {
  process.stdout.write(`${moduleName} => ${req.resolve(moduleName)}\n`);
}
'@

  & node -e $resolveScript $RuntimeRoot
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Runtime module resolution preflight failed from packaged runtime root: $RuntimeRoot"
  }
}

function Write-ReusableLauncherPath([System.IO.FileInfo]$Launcher, [string]$TemporaryRoot) {
  if (-not $Launcher -or [string]::IsNullOrWhiteSpace($persistLauncherPathFile)) {
    return $Launcher
  }

  $launcherPath = $Launcher.FullName
  if (
    -not [string]::IsNullOrWhiteSpace($TemporaryRoot) -and
    $launcherPath.StartsWith($TemporaryRoot, [System.StringComparison]::OrdinalIgnoreCase)
  ) {
    $stageDir = if ([string]::IsNullOrWhiteSpace($persistLauncherDir)) {
      Join-Path $env:RUNNER_TEMP "eliza-home-windows-ui-launcher"
    } else {
      $persistLauncherDir
    }

    $appRoot = Split-Path -Parent (Split-Path -Parent $launcherPath)
    Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
    Copy-Item -Path (Join-Path $appRoot "*") -Destination $stageDir -Recurse -Force
    $launcherPath = Join-Path $stageDir "bin\\launcher.exe"
  }

  $pathFileParent = Split-Path -Parent $persistLauncherPathFile
  if ($pathFileParent) {
    New-Item -ItemType Directory -Force -Path $pathFileParent | Out-Null
  }
  Set-Content -Path $persistLauncherPathFile -Value $launcherPath -Encoding utf8
  return Get-Item $launcherPath
}

function Stop-ElizaHomeProcesses() {
  Get-Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.ProcessName -in @("launcher", "bun") -or
      $_.ProcessName -like "Eliza*" -or
      $_.ProcessName -like "Setup*"
    } |
    Stop-Process -Force
}

function Get-ObservedBackendPorts([int]$DefaultPort) {
  $ports = [System.Collections.Generic.List[int]]::new()
  $ports.Add($DefaultPort)

  if (-not (Test-Path $startupLog)) {
    return $ports.ToArray()
  }

  $logLines = Get-Content $startupLog -Tail 200 -ErrorAction SilentlyContinue
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

  # Fallback sweep for launcher flows that start on dynamic ports before the
  # startup log is written or when the log path differs on CI runners.
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
    # Ignore runner-specific socket enumeration failures.
  }

  return $ports.ToArray()
}

Write-Host "Artifacts dir: $resolvedArtifactsDir"
if ($resolvedBuildDir) {
  Write-Host "Build dir: $resolvedBuildDir"
}
Write-SmokeEvent "smoke.contract" @{
  installerRequired = [bool]$PreferInstaller
  launcherLivenessRequired = $true
  backendHealthRequired = $true
  preflightFatal = $false
}
Write-PathDiagnostics -Label "artifacts_dir" -PathValue $resolvedArtifactsDir
if ($resolvedBuildDir) {
  Write-PathDiagnostics -Label "build_dir" -PathValue $resolvedBuildDir
}
Write-PathDiagnostics -Label "self_extraction_root" -PathValue $selfExtractionRoot
Write-PathDiagnostics -Label "smoke_temp_root" -PathValue $smokeTempRoot
Write-PathDiagnostics -Label "startup_log" -PathValue $startupLog
Write-PathDiagnostics -Label "launcher_path_file" -PathValue $persistLauncherPathFile

Stop-ElizaHomeProcesses
$env:ELECTROBUN_CONSOLE = "1"

if (Test-Path $selfExtractionRoot) {
  Remove-Item $selfExtractionRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$launcher = Find-Launcher $resolvedArtifactsDir
$launcherSource = $null
$packagedTarball = $null
$installer = $null
$installerProcess = $null
$launcherProcess = $null
$launcherStarted = $false
$runtimeValidated = $false
$installerExitWarned = $false
$launcherSeenRunning = $false

if ($resolvedBuildDir) {
  $launcher = Find-Launcher $resolvedBuildDir
  if ($launcher) {
    $launcherSource = "build"
  }
}

if (-not $launcher) {
  $launcher = Find-Launcher $resolvedArtifactsDir
  if ($launcher) {
    $launcherSource = "artifacts"
  }
}

$installer = Get-ChildItem -Path $resolvedArtifactsDir -File -Filter "*Setup*.exe" -ErrorAction SilentlyContinue |
  Sort-Object Length -Descending |
  Select-Object -First 1
if ($installer) {
  Write-PathDiagnostics -Label "installer_exe" -PathValue $installer.FullName
}
if (-not $installer) {
  $installerZip = Get-ChildItem -Path $resolvedArtifactsDir -File -Filter "*Setup*.zip" -ErrorAction SilentlyContinue |
    Sort-Object Length -Descending |
    Select-Object -First 1
  if ($installerZip) {
    Write-PathDiagnostics -Label "installer_zip" -PathValue $installerZip.FullName
    New-Item -ItemType Directory -Force -Path $tempExtractDir | Out-Null
    Expand-Archive -Path $installerZip.FullName -DestinationPath $tempExtractDir -Force
    $installer = Get-ChildItem -Path $tempExtractDir -Recurse -File -Filter "*Setup*.exe" -ErrorAction SilentlyContinue |
      Sort-Object Length -Descending |
      Select-Object -First 1
    if ($installer) {
      Write-PathDiagnostics -Label "installer_from_zip" -PathValue $installer.FullName
    }
  }
}
Write-SmokeEvent "preflight.inventory" @{
  hasBuildLauncher = [bool]($resolvedBuildDir -and (Find-Launcher $resolvedBuildDir))
  hasArtifactsLauncher = [bool](Find-Launcher $resolvedArtifactsDir)
  hasInstaller = [bool]$installer
  selfExtractionExists = [bool](Test-Path $selfExtractionRoot)
}

if ($PreferInstaller -and $installer) {
  Write-Host "Using installer (preferred): $($installer.FullName)"
  # The electrobun Windows installer is a Zig-based self-extractor, not an NSIS installer.
  # It does not accept /S or /D= flags. Start it and poll for extraction + health.
  Write-SmokeEvent "installer.start" @{ path = $installer.FullName; source = "preferred" }
  $installerProcess = Start-Process -FilePath $installer.FullName -WorkingDirectory (Split-Path -Parent $installer.FullName) -PassThru
  $launcher = $null
  $launcherSource = "installed via self-extractor"
} elseif (-not $launcher) {
  $packagedTarball = Get-ChildItem -Path $resolvedArtifactsDir -File -Filter "*.tar.zst" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if ($packagedTarball) {
    Write-Host "Using packaged tarball: $($packagedTarball.FullName)"
    try {
      Expand-PackagedTarball -ArchivePath $packagedTarball.FullName -DestinationPath $tempExtractDir
      $launcher = Find-Launcher $tempExtractDir
      if (-not $launcher) {
        Write-Warning "Packaged tarball extracted but no launcher.exe was found. Falling back to installer path."
      } else {
        $launcherSource = "packaged tarball"
      }
    } catch {
      Write-Warning "Failed to extract packaged tarball: $($_.Exception.Message)"
      Write-Warning "Falling back to installer path."
    }
  }

  if ($launcher) {
    $launcher = Write-ReusableLauncherPath -Launcher $launcher -TemporaryRoot $tempExtractDir
    Write-SmokeEvent "launcher.discovery" @{ source = $launcherSource; path = $launcher.FullName }
    Write-Host "Using $launcherSource launcher: $($launcher.FullName)"
    $runtimeRoot = Resolve-RuntimeRootFromLauncher -Launcher $launcher
    if ($runtimeRoot) {
      Write-SmokeEvent "runtime.discovery" @{
        source = $launcherSource
        runtimeRoot = $runtimeRoot
        candidatesTried = @($script:runtimeRootCandidatesTried)
      }
      Write-Host "Validating packaged runtime at: $runtimeRoot"
      Test-PackagedRuntimeSurface -RuntimeRoot $runtimeRoot
      $runtimeValidated = $true
    } else {
      Write-Warning "Could not resolve runtime root from launcher path before startup. Continuing to launch for extraction/handoff."
    }
    $launcherDir = Split-Path -Parent $launcher.FullName
    $launcherProcess = Start-Process -FilePath $launcher.FullName -WorkingDirectory $launcherDir -PassThru
    $launcherStarted = $true
  } else {
    if (-not $installer) {
      throw "No installer executable found for Windows smoke test."
    }

    Write-Host "Using installer: $($installer.FullName)"
    # Electrobun Windows installer is a Zig self-extractor; no NSIS /S /D= flags.
    Write-SmokeEvent "installer.start" @{ path = $installer.FullName; source = "fallback" }
    $installerProcess = Start-Process -FilePath $installer.FullName -WorkingDirectory (Split-Path -Parent $installer.FullName) -PassThru
    $launcher = $null
    $launcherSource = "installed via self-extractor"
  }
} else {
  $launcher = Write-ReusableLauncherPath -Launcher $launcher -TemporaryRoot $tempExtractDir
  Write-SmokeEvent "launcher.discovery" @{ source = $launcherSource; path = $launcher.FullName }
  Write-Host "Using $launcherSource launcher: $($launcher.FullName)"
  $runtimeRoot = Resolve-RuntimeRootFromLauncher -Launcher $launcher
  if ($runtimeRoot) {
    Write-SmokeEvent "runtime.discovery" @{
      source = $launcherSource
      runtimeRoot = $runtimeRoot
      candidatesTried = @($script:runtimeRootCandidatesTried)
    }
    Write-Host "Validating packaged runtime at: $runtimeRoot"
    Test-PackagedRuntimeSurface -RuntimeRoot $runtimeRoot
    $runtimeValidated = $true
  } else {
    Write-Warning "Could not resolve runtime root from launcher path before startup. Continuing to launch for extraction/handoff."
  }
  $launcherDir = Split-Path -Parent $launcher.FullName
  $launcherProcess = Start-Process -FilePath $launcher.FullName -WorkingDirectory $launcherDir -PassThru
  $launcherStarted = $true
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$healthy = $false

try {
  while ((Get-Date) -lt $deadline) {
    if (
      $installerProcess -and
      $installerProcess.HasExited -and
      -not $installerExitWarned -and
      $installerProcess.ExitCode -ne 0
    ) {
      Write-Warning "Windows installer exited with non-zero code: $($installerProcess.ExitCode). Continuing with launcher/health validation."
      Write-SmokeEvent "installer.exit" @{
        code = $installerProcess.ExitCode
        warning = $true
      }
      $installerExitWarned = $true
    }

    if (-not $launcher) {
      $launcher = Get-StagedLauncherFromPathFile -PathFile $persistLauncherPathFile
      if ($launcher) {
        $launcherSource = "persisted-launcher-path"
        Write-SmokeEvent "launcher.discovery" @{ source = $launcherSource; path = $launcher.FullName }
      }
    }

    if (-not $launcher) {
      $launcher = Find-Launcher $selfExtractionRoot
      if ($launcher) {
        $launcher = Write-ReusableLauncherPath -Launcher $launcher -TemporaryRoot $null
        $launcherSource = "self-extraction"
        Write-SmokeEvent "launcher.discovery" @{ source = $launcherSource; path = $launcher.FullName }
        Write-Host "Found extracted launcher: $($launcher.FullName)"
      }
    }

    if (-not $launcher -and $resolvedBuildDir) {
      $launcher = Find-Launcher $resolvedBuildDir
      if ($launcher) {
        $launcherSource = "build-fallback"
        Write-SmokeEvent "launcher.discovery" @{ source = $launcherSource; path = $launcher.FullName }
      }
    }

    if (-not $launcher) {
      $launcher = Find-Launcher $resolvedArtifactsDir
      if ($launcher) {
        $launcherSource = "artifacts-fallback"
        Write-SmokeEvent "launcher.discovery" @{ source = $launcherSource; path = $launcher.FullName }
      }
    }

    if ($launcher -and -not $runtimeValidated) {
      $runtimeRoot = Resolve-RuntimeRootFromLauncher -Launcher $launcher
      if ($runtimeRoot) {
        Write-SmokeEvent "runtime.discovery" @{
          source = $launcherSource
          runtimeRoot = $runtimeRoot
          candidatesTried = @($script:runtimeRootCandidatesTried)
        }
        Write-Host "Validating packaged runtime at: $runtimeRoot"
        Test-PackagedRuntimeSurface -RuntimeRoot $runtimeRoot
        $runtimeValidated = $true
      }
    }

    if (
      $launcher -and
      -not (Get-Process -Name "launcher" -ErrorAction SilentlyContinue) -and
      (
        -not $launcherStarted -or
        ($launcherProcess -and $launcherProcess.HasExited)
      )
    ) {
      $launcherDir = Split-Path -Parent $launcher.FullName
      $launcherProcess = Start-Process -FilePath $launcher.FullName -WorkingDirectory $launcherDir -PassThru
      $launcherStarted = $true
      Write-SmokeEvent "launcher.start" @{ path = $launcher.FullName; source = $launcherSource }
      Write-Host "Started extracted launcher: $($launcher.FullName)"
    }
    if (Get-Process -Name "launcher" -ErrorAction SilentlyContinue) {
      $launcherSeenRunning = $true
    }

    if (Test-Path $startupLog) {
      $recentLog = Get-Content $startupLog -Tail 200 -ErrorAction SilentlyContinue
      if ($recentLog -match 'Cannot find module|Child process exited with code|Failed to start:') {
        Write-Host "Recent startup log:"
        $recentLog
        throw "Windows packaged app reported a startup failure."
      }
    }

    foreach ($port in Get-ObservedBackendPorts $BackendPort) {
      foreach ($path in @("/api/health", "/api/auth/status")) {
        $probeAttempts.Add("$port$path") | Out-Null
        try {
          $response = Invoke-WebRequest -Uri "http://127.0.0.1:$port$path" -UseBasicParsing -TimeoutSec 2
          if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            $healthy = $true
            Write-SmokeEvent "endpoint.healthy" @{ port = $port; path = $path; status = $response.StatusCode }
            Write-Host "Backend health check passed on port $port via $path."
            break
          }
        } catch {
          # ignore and continue checking other endpoints/ports
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
    Write-SmokeEvent "runtime.root-candidates" @{
      candidatesTried = @($script:runtimeRootCandidatesTried)
      count = $script:runtimeRootCandidatesTried.Count
    }
    if ($installerProcess) {
      Write-Host "Installer exited: $($installerProcess.HasExited)"
      if ($installerProcess.HasExited) {
        Write-Host "Installer exit code: $($installerProcess.ExitCode)"
      }
    }
    if ($launcherProcess) {
      Write-Host "Launcher exited: $($launcherProcess.HasExited)"
      if ($launcherProcess.HasExited) {
        Write-Host "Launcher exit code: $($launcherProcess.ExitCode)"
      }
    }
    if (Test-Path $startupLog) {
      Write-Host "Recent startup log:"
      Get-Content $startupLog -Tail 200
    }
    if (Test-Path $selfExtractionRoot) {
      Write-Host "Self-extraction contents:"
      Get-ChildItem -Path $selfExtractionRoot -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName
    }
    throw "Windows packaged app did not become healthy within $TimeoutSeconds seconds."
  }
  if (-not $launcherSeenRunning) {
    Write-SmokeEvent "contract.failure" @{
      reason = "launcher-not-observed"
      launcherPath = if ($launcher) { $launcher.FullName } else { $null }
      launcherSource = $launcherSource
    }
    throw "Windows packaged app became healthy but launcher process was not observed running."
  }
  Write-SmokeEvent "endpoint.probe-matrix" @{
    attempts = @($probeAttempts | Sort-Object)
    totalAttempts = $probeAttempts.Count
  }
  Write-SmokeEvent "runtime.root-candidates" @{
    candidatesTried = @($script:runtimeRootCandidatesTried)
    count = $script:runtimeRootCandidatesTried.Count
  }
  Write-SmokeEvent "contract.pass" @{
    launcherObserved = $launcherSeenRunning
    backendHealthy = $healthy
    launcherPath = if ($launcher) { $launcher.FullName } else { $null }
    launcherSource = $launcherSource
  }
} finally {
  Stop-ElizaHomeProcesses
  if (Test-Path $tempExtractDir) {
    Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
