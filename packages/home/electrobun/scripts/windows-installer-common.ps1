Set-StrictMode -Version Latest

function Get-ElizaHomeCanonicalPath([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }

  try {
    return [System.IO.Path]::GetFullPath($Value)
  } catch {
    return $Value
  }
}

function Get-ElizaHomePathDiagnostic([string]$PathValue) {
  $resolvedPath = Get-ElizaHomeCanonicalPath $PathValue
  if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
    return [pscustomobject]@{
      path = $PathValue
      canonicalPath = $resolvedPath
      length = 0
      risk = "unknown"
    }
  }

  $length = $resolvedPath.Length
  $risk = if ($length -ge 250) {
    "high"
  } elseif ($length -ge 220) {
    "warning"
  } else {
    "ok"
  }

  return [pscustomobject]@{
    path = $PathValue
    canonicalPath = $resolvedPath
    length = $length
    risk = $risk
  }
}

function New-ElizaHomeWindowsShortTempRoot([string]$Prefix = "ehw") {
  $baseRoot = if ($env:ELIZA_HOME_WINDOWS_TEMP_ROOT) {
    $env:ELIZA_HOME_WINDOWS_TEMP_ROOT
  } elseif (Test-Path "C:\t") {
    "C:\t"
  } else {
    "C:\t"
  }

  if (-not (Test-Path $baseRoot)) {
    New-Item -ItemType Directory -Force -Path $baseRoot | Out-Null
  }

  $guid = [Guid]::NewGuid().ToString("N").Substring(0, 10)
  $root = Join-Path $baseRoot "$Prefix\$guid"
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return (Get-ElizaHomeCanonicalPath $root)
}

function Get-ElizaHomeWindowsChannelLabel([string]$BuildEnv) {
  if ([string]::IsNullOrWhiteSpace($BuildEnv)) {
    return "canary"
  }

  return $BuildEnv.Trim().ToLowerInvariant()
}

function Get-ElizaHomeWindowsAssetBaseName([string]$BuildEnv) {
  $channel = Get-ElizaHomeWindowsChannelLabel -BuildEnv $BuildEnv
  if ($channel -eq "stable") {
    return "stable-win-x64-ElizaHome-Setup"
  }

  return "$channel-win-x64-ElizaHome-Setup-$channel"
}

function Get-ElizaHomeWindowsInstallContract(
  [string]$BuildEnv = "canary",
  [string]$LocalAppData = $env:LOCALAPPDATA,
  [string]$AppData = $env:APPDATA
) {
  $channel = Get-ElizaHomeWindowsChannelLabel -BuildEnv $BuildEnv
  # Keep the installed root short enough for Win10/11 systems where long paths are still off.
  $programsRoot = Join-Path $LocalAppData "EH"
  $installRoot = Join-Path $programsRoot $channel

  $shortcutDisplay = if ($channel -eq "stable") {
    "Eliza Home"
  } else {
    $titledChannel = (Get-Culture).TextInfo.ToTitleCase($channel)
    "Eliza Home ($titledChannel)"
  }

  $startMenuDir = Join-Path $AppData "Microsoft\Windows\Start Menu\Programs\Eliza Home"
  $appRoot = $installRoot

  [pscustomobject]@{
    Channel = $channel
    InstallRoot = $installRoot
    AppRoot = $appRoot
    LauncherPath = Join-Path $appRoot "bin\launcher.exe"
    RuntimeRoot = Join-Path $appRoot "resources\app\home-dist"
    StartMenuDir = $startMenuDir
    ShortcutName = "$shortcutDisplay.lnk"
    ShortcutPath = Join-Path $startMenuDir "$shortcutDisplay.lnk"
    MetadataPath = Join-Path $installRoot "install-metadata.json"
  }
}

function Get-ElizaHomeRawBundleCandidates([string]$BuildDir) {
  if ([string]::IsNullOrWhiteSpace($BuildDir) -or -not (Test-Path $BuildDir)) {
    return @()
  }

  $launchers = Get-ChildItem -Path $BuildDir -Recurse -File -Filter "launcher.exe" -ErrorAction SilentlyContinue
  $bundleRoots = foreach ($launcher in $launchers) {
    $bundleRoot = Split-Path -Parent (Split-Path -Parent $launcher.FullName)
    if (
      (Test-Path (Join-Path $bundleRoot "bin\launcher.exe")) -and
      (
        (Test-Path (Join-Path $bundleRoot "resources")) -or
        (Test-Path (Join-Path $bundleRoot "Resources"))
      )
    ) {
      $bundleRoot
    }
  }

  return $bundleRoots |
    Sort-Object Length, FullName -Unique
}

function Resolve-ElizaHomeRawBundlePath([string]$BuildDir) {
  $candidates = @(Get-ElizaHomeRawBundleCandidates -BuildDir $BuildDir)
  if ($candidates.Count -eq 0) {
    throw "Could not find a Windows raw bundle under $BuildDir"
  }

  return $candidates[0]
}

function Get-ElizaHomeWindowsPayloadArchiveCandidates(
  [string]$ArtifactsDir,
  [string]$BuildDir
) {
  $searchRoots = @($ArtifactsDir, $BuildDir) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) }

  $candidates = foreach ($root in $searchRoots) {
    Get-ChildItem -Path $root -Recurse -File -Filter "*-win-*.tar.zst" -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -notlike "*Setup*" -and
        $_.FullName -notmatch "[\\/]\.installer[\\/]"
      } |
      Select-Object -ExpandProperty FullName
  }

  return $candidates | Sort-Object Length, FullName -Unique
}

function Resolve-ElizaHomeWindowsPayloadSource(
  [string]$ArtifactsDir,
  [string]$BuildDir
) {
  $archiveCandidates = @(Get-ElizaHomeWindowsPayloadArchiveCandidates -ArtifactsDir $ArtifactsDir -BuildDir $BuildDir)
  if ($archiveCandidates.Count -gt 0) {
    return [pscustomobject]@{
      SourceLayer = "packaged_archive"
      Path = $archiveCandidates[0]
    }
  }

  $rawBundleCandidates = @(Get-ElizaHomeRawBundleCandidates -BuildDir $BuildDir)
  if ($rawBundleCandidates.Count -gt 0) {
    return [pscustomobject]@{
      SourceLayer = "raw_bundle_directory"
      Path = $rawBundleCandidates[0]
    }
  }

  throw "Could not find a Windows packaged payload archive under $ArtifactsDir or $BuildDir, and no raw bundle fallback exists."
}

function Resolve-ElizaHomeWindowsRuntimeRoot([string]$AppRoot) {
  $candidates = @(
    (Join-Path $AppRoot "resources\app\home-dist"),
    (Join-Path $AppRoot "Resources\app\home-dist")
  )

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      return [pscustomobject]@{
        runtimeRoot = $candidate
        candidates = $candidates
      }
    }
  }

  return [pscustomobject]@{
    runtimeRoot = $null
    candidates = $candidates
  }
}

function Get-ElizaHomeWindowsPayloadInspection([string]$AppRoot) {
  $resolvedAppRoot = Get-ElizaHomeCanonicalPath $AppRoot
  $launcherPath = Join-Path $resolvedAppRoot "bin\launcher.exe"
  $runtime = Resolve-ElizaHomeWindowsRuntimeRoot -AppRoot $resolvedAppRoot
  $iconCandidates = @(
    (Join-Path $resolvedAppRoot "resources\appIcon.ico"),
    (Join-Path $resolvedAppRoot "Resources\appIcon.ico")
  )
  $iconPath = $iconCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

  [pscustomobject]@{
    appRoot = $resolvedAppRoot
    launcherPath = $launcherPath
    runtimeRoot = $runtime.runtimeRoot
    runtimeRootCandidates = $runtime.candidates
    iconPath = $iconPath
    iconCandidates = $iconCandidates
    launcherExists = [bool](Test-Path $launcherPath)
    runtimeExists = [bool]($runtime.runtimeRoot -and (Test-Path $runtime.runtimeRoot))
  }
}

function Get-ElizaHomeInstalledPathLayoutDiagnostic(
  [string]$PayloadAppRoot,
  [string]$InstallRoot
) {
  $resolvedPayloadAppRoot = Get-ElizaHomeCanonicalPath $PayloadAppRoot
  $resolvedInstallRoot = Get-ElizaHomeCanonicalPath $InstallRoot
  $maxAllowedLength = 259
  $fileCount = 0
  $maxInstalledLength = 0
  $maxInstalledPath = $null
  $maxRelativePath = $null

  if (-not (Test-Path $resolvedPayloadAppRoot)) {
    return [pscustomobject]@{
      payloadAppRoot = $resolvedPayloadAppRoot
      installRoot = $resolvedInstallRoot
      fileCount = 0
      maxAllowedLength = $maxAllowedLength
      maxInstalledLength = 0
      maxInstalledPath = $null
      maxRelativePath = $null
      withinLimit = $false
      overflow = 0
    }
  }

  Get-ChildItem -Path $resolvedPayloadAppRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $fileCount += 1
    $relativePath = $_.FullName.Substring($resolvedPayloadAppRoot.Length).TrimStart('\', '/')
    $installedPath = Join-Path $resolvedInstallRoot $relativePath
    $installedLength = $installedPath.Length
    if ($installedLength -gt $maxInstalledLength) {
      $maxInstalledLength = $installedLength
      $maxInstalledPath = $installedPath
      $maxRelativePath = $relativePath
    }
  }

  return [pscustomobject]@{
    payloadAppRoot = $resolvedPayloadAppRoot
    installRoot = $resolvedInstallRoot
    fileCount = $fileCount
    maxAllowedLength = $maxAllowedLength
    maxInstalledLength = $maxInstalledLength
    maxInstalledPath = $maxInstalledPath
    maxRelativePath = $maxRelativePath
    withinLimit = ($maxInstalledLength -le $maxAllowedLength)
    overflow = [Math]::Max(0, $maxInstalledLength - $maxAllowedLength)
  }
}

function New-ElizaHomeStartMenuShortcut(
  [string]$ShortcutPath,
  [string]$TargetPath,
  [string]$WorkingDirectory,
  [string]$Description = "Launch Eliza Home"
) {
  $shortcutDir = Split-Path -Parent $ShortcutPath
  New-Item -ItemType Directory -Force -Path $shortcutDir | Out-Null

  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($ShortcutPath)
  $shortcut.TargetPath = $TargetPath
  $shortcut.WorkingDirectory = $WorkingDirectory
  $shortcut.IconLocation = $TargetPath
  $shortcut.Description = $Description
  $shortcut.Save()
}

function Remove-ElizaHomeInstalledContract([pscustomobject]$Contract) {
  if ($null -eq $Contract) {
    return
  }

  if (Test-Path $Contract.InstallRoot) {
    Remove-Item -Path $Contract.InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  if (Test-Path $Contract.ShortcutPath) {
    Remove-Item -Path $Contract.ShortcutPath -Force -ErrorAction SilentlyContinue
  }
}
