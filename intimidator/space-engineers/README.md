# Space Engineers server

Windows VM on intimidator, installed by steamcmd to `C:\seserver`, reachable
as `se.rooday.com` (game/query port UDP 27016, forwarded to the VM's reserved
IP). Kuma watches it with a GameDig monitor on `se.rooday.com:27016`.

The GUI (`SpaceEngineersDedicated.exe` without arguments) is only for
configuring the world and mods. The server itself runs headless in console
mode, started by Scheduled Tasks through `se-server.ps1`:

| Task | Trigger | Runs |
|---|---|---|
| `SE server start` | VM boot (+1 min) | `se-server.ps1 -Action Start -InstancePath <folder>` |
| `SE server update` | daily 05:30 | `se-server.ps1 -Action Update -InstancePath <folder>`: if Steam has a newer build, stop, update, start; else make sure it is running |

Both run as your Windows account, whether or not you are logged in. Pass
`-InstancePath` with the folder holding `SpaceEngineers-Dedicated.cfg` and the
world (where the GUI saved it); without it the console server finds no world
and quits. Find it with:

```powershell
Get-ChildItem C:\ProgramData, $env:APPDATA, C:\seserver -Recurse -Filter SpaceEngineers-Dedicated.cfg -ErrorAction SilentlyContinue | Select-Object FullName, LastWriteTime
```

`Start` only reports success once the server answers a Steam query on port
27016 (the same check Kuma makes); a server stuck at "press any key" is
stopped and reported as a failure.

## Install

In an admin PowerShell on the VM. Adjust `-SteamCmd` in the task arguments
if steamcmd is not at `C:\steamcmd\steamcmd.exe`.

```powershell
New-Item -ItemType Directory -Force C:\se-tools | Out-Null
Invoke-WebRequest -UseBasicParsing -OutFile C:\se-tools\se-server.ps1 `
  https://raw.githubusercontent.com/ROODAY/docker-compose/main/intimidator/space-engineers/se-server.ps1
Unblock-File C:\se-tools\se-server.ps1

# 1. Check what is installed vs. the latest Steam build (changes nothing)
powershell -NoProfile -ExecutionPolicy Bypass -File C:\se-tools\se-server.ps1 -Action Check

# 2. Stop the server in the GUI and close it, then test the headless start
$inst = '<folder holding SpaceEngineers-Dedicated.cfg>'
powershell -NoProfile -ExecutionPolicy Bypass -File C:\se-tools\se-server.ps1 -Action Start -InstancePath $inst

# 3. Register the two tasks (asks for your Windows password once)
$user = "$env:USERDOMAIN\$env:USERNAME"
$pw = (Get-Credential $user -Message 'Windows password for the SE tasks').GetNetworkCredential().Password
$run = { param($a) New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\se-tools\se-server.ps1 -Action $a -InstancePath `"$inst`"" }
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
  -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
$boot = New-ScheduledTaskTrigger -AtStartup; $boot.Delay = 'PT1M'
Register-ScheduledTask -TaskName 'SE server start' -Action (& $run Start) -Trigger $boot `
  -Settings $settings -User $user -Password $pw -RunLevel Highest -Force
Register-ScheduledTask -TaskName 'SE server update' -Action (& $run Update) `
  -Trigger (New-ScheduledTaskTrigger -Daily -At 05:30) `
  -Settings $settings -User $user -Password $pw -RunLevel Highest -Force
```

If you sign in to Windows with a Microsoft account, the password is that
account's password (not the PIN).

## Day to day

- **Change config or mods:** `se-server.ps1 -Action Stop`, edit and save in
  the GUI (do not start the server from the GUI), then
  `se-server.ps1 -Action Start -InstancePath <folder>`.
- **Update now:** `se-server.ps1 -Action Update`. Add `-Validate` to have
  steamcmd verify every file, or `-Force` to reinstall and restart anyway.
- **Log:** `C:\seserver\se-server.log` (steamcmd output included).

## Shutdown

There is no clean stop for a headless server: `-Action Stop` and a Windows
shutdown both end the process, so anything since the last autosave is
lost. Keep the autosave interval short in the GUI (for example 5 minutes).
Windows shutdown ends it the same way, so a shutdown task would add nothing.
The server's Remote API (listening on 8080) could do a clean save-then-stop;
not set up yet.
