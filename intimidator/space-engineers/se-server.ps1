<#
.SYNOPSIS
  Start, stop, check or update the Space Engineers dedicated server.

.DESCRIPTION
  Runs on the Windows VM. The server runs headless in console mode
  (SpaceEngineersDedicated.exe -console), using the config the GUI saves.
  See README.md for the Scheduled Tasks that call this.

    se-server.ps1 -Action Check     # installed vs latest Steam build, changes nothing
    se-server.ps1 -Action Start     # start it if it is not running
    se-server.ps1 -Action Stop      # stop it (before using the GUI, for example)
    se-server.ps1 -Action Update    # if a newer build exists: stop, update, start
    se-server.ps1 -Action Update -Force      # update and restart even if current
    se-server.ps1 -Action Update -Validate   # also verify every installed file

  Exit code 0 on success, 1 on failure. Log: <InstallDir>\se-server.log.
#>
param(
  [Parameter(Mandatory)] [ValidateSet('Check', 'Start', 'Stop', 'Update')] [string] $Action,
  [string] $SteamCmd = 'C:\steamcmd\steamcmd.exe',
  [string] $InstallDir = 'C:\seserver',
  # Instance folder holding SpaceEngineers-Dedicated.cfg. Empty = the default
  # the GUI uses (%APPDATA%\SpaceEngineersDedicated of the account running this).
  [string] $InstancePath = '',
  # Optional Uptime Kuma push monitor, pinged after a successful Update run.
  [string] $PushUrl = '',
  [switch] $Force,
  [switch] $Validate
)

$ErrorActionPreference = 'Stop'
$AppId = 298740
$Exe = Join-Path $InstallDir 'DedicatedServer64\SpaceEngineersDedicated.exe'
$Manifest = Join-Path $InstallDir "steamapps\appmanifest_$AppId.acf"
$LogFile = Join-Path $InstallDir 'se-server.log'

function Log([string] $msg) {
  $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Action, $msg
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

function Get-ServerProcess {
  Get-Process -Name SpaceEngineersDedicated -ErrorAction SilentlyContinue
}

function Get-InstalledBuild {
  if (-not (Test-Path $Manifest)) { return $null }
  $m = Select-String -Path $Manifest -Pattern '"buildid"\s+"(\d+)"' | Select-Object -First 1
  if ($m) { return $m.Matches[0].Groups[1].Value }
  return $null
}

function Get-LatestBuild {
  # app_info_update refreshes steamcmd's cached app info before printing it.
  $out = & $SteamCmd +login anonymous +app_info_update 1 +app_info_print $AppId +quit 2>&1 | Out-String
  $m = [regex]::Match($out, '"public"\s*\{\s*"buildid"\s*"(\d+)"')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Start-Server {
  if (Get-ServerProcess) { Log 'already running'; return }
  if (-not (Test-Path $Exe)) { throw "not found: $Exe" }
  $argList = @('-console')
  if ($InstancePath) { $argList += @('-path', "`"$InstancePath`"") }
  Start-Process -FilePath $Exe -ArgumentList $argList -WorkingDirectory (Split-Path $Exe) -WindowStyle Hidden
  Start-Sleep -Seconds 20
  if (-not (Get-ServerProcess)) { throw 'server exited right after starting; run it once by hand with -console to see why' }
  Log "started ($Exe $($argList -join ' '))"
}

function Stop-Server {
  $p = Get-ServerProcess
  if (-not $p) { Log 'not running'; return }
  # A headless console server has no window to close and no stop command,
  # so this is a hard stop: anything since the last autosave is lost.
  $p | Stop-Process -Force
  $p | Wait-Process -Timeout 60 -ErrorAction SilentlyContinue
  if (Get-ServerProcess) { throw 'server did not stop' }
  Log 'stopped'
}

try {
  switch ($Action) {
    'Start' { Start-Server }
    'Stop'  { Stop-Server }
    'Check' {
      $installed = Get-InstalledBuild
      $latest = Get-LatestBuild
      $running = [bool](Get-ServerProcess)
      Log "installed build: $installed, latest build: $latest, running: $running"
      if (-not $latest) { throw 'could not read the latest build from steamcmd' }
      if ($installed -eq $latest) { Log 'up to date' } else { Log 'UPDATE AVAILABLE' }
    }
    'Update' {
      $installed = Get-InstalledBuild
      $latest = Get-LatestBuild
      Log "installed build: $installed, latest build: $latest"
      if (-not $Force -and -not $Validate -and $latest -and $installed -eq $latest) {
        Log 'up to date; nothing to do'
        Start-Server
      } else {
        $wasRunning = [bool](Get-ServerProcess)
        Stop-Server
        $steamArgs = @('+force_install_dir', $InstallDir, '+login', 'anonymous', '+app_update', $AppId)
        if ($Validate) { $steamArgs += 'validate' }
        $steamArgs += '+quit'
        $out = & $SteamCmd @steamArgs 2>&1 | Out-String
        Add-Content -Path $LogFile -Value $out
        if ($out -notmatch "Success! App '$AppId' fully installed") {
          if ($wasRunning) { Start-Server }
          throw 'steamcmd did not report success (output is in the log)'
        }
        Log "updated to build $(Get-InstalledBuild)"
        Start-Server
      }
      if ($PushUrl) {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Uri "$PushUrl`?status=up&msg=OK" | Out-Null
      }
    }
  }
  exit 0
} catch {
  Log "ERROR: $($_.Exception.Message)"
  exit 1
}
