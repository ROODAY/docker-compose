<#
.SYNOPSIS
  Start, stop, check or update the Space Engineers dedicated server.

.DESCRIPTION
  Runs on the Windows VM. The server runs headless in console mode
  (SpaceEngineersDedicated.exe -console -path <instance>). Save and Stop use
  the server's Remote API (key and port from the instance's
  SpaceEngineers-Dedicated.cfg); Stop only force-kills if that fails.
  See README.md for the Scheduled Tasks and shutdown script that call this.

    se-server.ps1 -Action Check     # installed vs latest Steam build, changes nothing
    se-server.ps1 -Action Start     # start it (detached, hidden) if it is not running
    se-server.ps1 -Action Save      # save the world now, keep running
    se-server.ps1 -Action Stop      # save, then stop (before using the GUI, at shutdown)
    se-server.ps1 -Action Update    # if a newer build exists: stop, update, start
    se-server.ps1 -Action Update -Force      # update and restart even if current
    se-server.ps1 -Action Update -Validate   # also verify every installed file

  Exit code 0 on success, 1 on failure. Log: <InstallDir>\se-server.log.
#>
param(
  [Parameter(Mandatory)] [ValidateSet('Check', 'Start', 'Save', 'Stop', 'Update')] [string] $Action,
  [string] $SteamCmd = 'C:\steamcmd\steamcmd.exe',
  [string] $InstallDir = 'C:\seserver',
  # Instance folder holding SpaceEngineers-Dedicated.cfg and the world. Empty
  # means the server's own default, which may not be where the GUI saved.
  [string] $InstancePath = '',
  # Game/query port from the server config; used to check it really is up.
  [int] $QueryPort = 27016,
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

function Test-ServerQuery {
  # Steam A2S_INFO on the game port, the same check Kuma's GameDig monitor makes.
  $udp = New-Object System.Net.Sockets.UdpClient
  try {
    $udp.Client.ReceiveTimeout = 3000
    $udp.Connect('127.0.0.1', $QueryPort)
    $req = [byte[]](0xFF, 0xFF, 0xFF, 0xFF) + [Text.Encoding]::ASCII.GetBytes("TSource Engine Query`0")
    [void]$udp.Send($req, $req.Length)
    $ep = New-Object System.Net.IPEndPoint ([Net.IPAddress]::Any, 0)
    $resp = $udp.Receive([ref]$ep)
    if ($resp.Length -ge 9 -and $resp[4] -eq 0x41) { # challenge: resend with it
      $req2 = $req + $resp[5..8]
      [void]$udp.Send($req2, $req2.Length)
      $resp = $udp.Receive([ref]$ep)
    }
    return ($resp.Length -gt 5 -and $resp[4] -eq 0x49)
  } catch {
    return $false
  } finally {
    $udp.Close()
  }
}

function Get-RemoteApi {
  # Remote API settings from the instance config; $null if unavailable.
  if (-not $InstancePath) { return $null }
  $cfg = Join-Path $InstancePath 'SpaceEngineers-Dedicated.cfg'
  if (-not (Test-Path $cfg)) { return $null }
  [xml] $x = Get-Content -Raw $cfg
  $enabled = $x.SelectSingleNode('//RemoteApiEnabled')
  $key = $x.SelectSingleNode('//RemoteSecurityKey')
  $port = $x.SelectSingleNode('//RemoteApiPort')
  if (-not $key -or -not $key.InnerText) { return $null }
  if ($enabled -and $enabled.InnerText -ne 'true') { return $null }
  $p = 8080
  if ($port -and $port.InnerText) { $p = [int]$port.InnerText }
  return @{ Key = $key.InnerText; Port = $p }
}

function Invoke-SeRemote([string] $Method, [string] $Resource) {
  # VRage Remote API: HMAC-SHA1 over "<path>\r\n<nonce>\r\n<date>\r\n" with
  # the base64-decoded security key, sent as "Authorization: <nonce>:<hash>".
  $api = Get-RemoteApi
  if (-not $api) { throw 'Remote API not configured (needs -InstancePath and RemoteSecurityKey in the cfg)' }
  $path = "/vrageremote/$Resource"
  $now = [DateTime]::UtcNow
  $date = $now.ToString('r')
  $nonce = [string](Get-Random -Minimum 100000 -Maximum 2147483647)
  $msg = "$path`r`n$nonce`r`n$date`r`n"
  $hmac = New-Object System.Security.Cryptography.HMACSHA1 (, [Convert]::FromBase64String($api.Key))
  $hash = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($msg)))
  # HttpWebRequest, not Invoke-RestMethod: Windows PowerShell refuses to set Date.
  $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$($api.Port)$path")
  $req.Method = $Method
  $req.Date = $now
  $req.Headers.Add('Authorization', "${nonce}:$hash")
  $req.Timeout = 30000
  if ($Method -ne 'GET') { $req.ContentLength = 0 }
  $resp = $req.GetResponse()
  try {
    $body = (New-Object System.IO.StreamReader ($resp.GetResponseStream())).ReadToEnd()
    return $body
  } finally {
    $resp.Close()
  }
}

function Test-RemoteApi {
  try { [void](Invoke-SeRemote 'GET' 'v1/server/ping'); return 'ok' }
  catch { return "unavailable ($($_.Exception.Message))" }
}

function Start-Server {
  if (Get-ServerProcess) {
    if (Test-ServerQuery) { Log 'already running'; return }
    # A failed start leaves the process waiting for a key press; clear it.
    Log 'process exists but the server does not answer queries; restarting it'
    Stop-Server
  }
  if (-not (Test-Path $Exe)) { throw "not found: $Exe" }
  $cmd = "`"$Exe`" -console"
  if ($InstancePath) { $cmd += " -path `"$InstancePath`"" }
  # Win32_Process.Create rather than Start-Process: the server is not a child
  # of this shell, so it never attaches to (or dies with) the caller's console.
  $startup = New-CimInstance -Namespace root/cimv2 -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
  $r = Invoke-CimMethod -Namespace root/cimv2 -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = $cmd; CurrentDirectory = (Split-Path $Exe); ProcessStartupInformation = $startup }
  if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create failed with code $($r.ReturnValue)" }
  # Loading the world takes a while; give it up to 5 minutes to answer.
  $deadline = (Get-Date).AddMinutes(5)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    if (Test-ServerQuery) { Log "started (pid $($r.ProcessId)) and answering on port $QueryPort"; return }
    if (-not (Get-ServerProcess)) { break }
  }
  Stop-Server
  throw "server did not answer on port $QueryPort; check InstancePath and the server log in the instance folder"
}

function Save-World {
  [void](Invoke-SeRemote 'PATCH' 'v1/session')
  Log 'save requested'
}

function Stop-Server {
  $p = Get-ServerProcess
  if (-not $p) { Log 'not running'; return }
  $clean = $false
  if (Test-ServerQuery) {
    try {
      Save-World
      Start-Sleep -Seconds 20   # let the save finish before shutting down
      [void](Invoke-SeRemote 'DELETE' 'v1/server')
      Log 'stop requested'
      $clean = $true
    } catch {
      Log "Remote API failed ($($_.Exception.Message)); falling back to a hard stop"
    }
  }
  if ($clean) {
    # The console server may sit at "press any key" after stopping, so the
    # process is ended once it stops answering, even if it has not exited.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and (Get-ServerProcess) -and (Test-ServerQuery)) { Start-Sleep -Seconds 5 }
    $p | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
  }
  if (Get-ServerProcess) { Get-ServerProcess | Stop-Process -Force }
  $p | Wait-Process -Timeout 60 -ErrorAction SilentlyContinue
  if (Get-ServerProcess) { throw 'server did not stop' }
  if ($clean) { Log 'stopped (saved first)' } else { Log 'stopped (hard stop, no save)' }
}

try {
  switch ($Action) {
    'Start' { Start-Server }
    'Save'  { Save-World }
    'Stop'  { Stop-Server }
    'Check' {
      $installed = Get-InstalledBuild
      $latest = Get-LatestBuild
      $running = [bool](Get-ServerProcess)
      $answering = Test-ServerQuery
      Log "installed build: $installed, latest build: $latest, process running: $running, answering on ${QueryPort}: $answering"
      if ($running) { Log "remote API: $(Test-RemoteApi)" }
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
