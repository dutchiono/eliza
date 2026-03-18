Set-StrictMode -Version Latest

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
  $programsRoot = Join-Path $LocalAppData "Programs\Eliza Home"
  $installRoot = if ($channel -eq "stable") {
    $programsRoot
  } else {
    Join-Path $programsRoot $channel
  }

  $shortcutDisplay = if ($channel -eq "stable") {
    "Eliza Home"
  } else {
    $titledChannel = (Get-Culture).TextInfo.ToTitleCase($channel)
    "Eliza Home ($titledChannel)"
  }

  $startMenuDir = Join-Path $AppData "Microsoft\Windows\Start Menu\Programs\Eliza Home"
  $appRoot = Join-Path $installRoot "app"

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
