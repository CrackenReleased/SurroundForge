<# Samsung optical 5.1 bridge, v0.1.9-local. Only controls this project's encoder. #>
[CmdletBinding()]
param([ValidateSet('Start','Stop','Status','Test','Diagnostics','EnableStartup','DisableStartup')][string]$Action='Start')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$build=Join-Path $root 'Runtime'
if(-not (Test-Path -LiteralPath (Join-Path $build 'engine.exe'))){$build=Join-Path $root 'source\engine\build\Release'}
$engine=Join-Path $build 'engine.exe'
$control=Join-Path $build 'bridge_control.exe'
$config=Join-Path $root 'bridge.conf'
$statePath=Join-Path $root 'bridge-state.json'
$log=Join-Path $root 'bridge.log'
$inputId=$null
$outputId=$null
if(Test-Path -LiteralPath $config) {
  foreach($line in Get-Content -LiteralPath $config) {
    if($line -match '^\s*in_id\s*=\s*(.+?)\s*$'){$inputId=$Matches[1]}
    if($line -match '^\s*out_id\s*=\s*(.+?)\s*$'){$outputId=$Matches[1]}
  }
}
$startup=Join-Path ([Environment]::GetFolderPath('Startup')) 'Samsung Optical 5.1.lnk'

function Invoke-Control([string[]]$Arguments) {
  $result=& $control @Arguments
  if($LASTEXITCODE -ne 0) {throw "Audio control failed ($LASTEXITCODE): $($Arguments -join ' ')"}
  return $result
}
function Test-VirtualMix51([string[]]$Format) {
  return ($Format -contains 'channels=6' -and $Format -contains 'rate=48000' -and $Format -contains 'mask=0x3f')
}
function Ensure-VirtualMix51 {
  $format=Invoke-Control @('--format',$inputId)
  if(-not (Test-VirtualMix51 $format)) {
    Write-Output 'Restoring the virtual 5.1 speaker assignments lost by Windows.'
    Invoke-Control @('--set-mix-51',$inputId) | Out-Null
    $format=Invoke-Control @('--format',$inputId)
    if(-not (Test-VirtualMix51 $format)){throw 'Virtual input must have six assigned 5.1 speakers (mask 0x3f) at 48000 Hz.'}
  }
}
function Save-BridgeDiagnostics {
  # Explicit, local evidence capture. Does not enable event channels or clear logs.
  $folder=Join-Path $root ('diagnostics\'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
  New-Item -ItemType Directory -Path $folder -Force | Out-Null
  $report=Join-Path $folder 'snapshot.txt'
  @("Captured: $((Get-Date).ToString('o'))",'Purpose: game surround investigation; last 24 hours of relevant events.',
    'No event logs are cleared, and no disabled trace channel is enabled.') | Set-Content -LiteralPath $report -Encoding UTF8
  foreach($args in @(@('--defaults'),@('--devices-json'))) {
    try {Invoke-Control $args | Add-Content -LiteralPath $report -Encoding UTF8} catch {"Unavailable: $_" | Add-Content -LiteralPath $report}
  }
  if($inputId) {
    foreach($args in @(@('--speaker-info',$inputId),@('--volume',$inputId),@('--sessions',$inputId))) {
      try {Invoke-Control $args | Add-Content -LiteralPath $report -Encoding UTF8} catch {"Unavailable: $_" | Add-Content -LiteralPath $report}
    }
  }
  if($outputId) {
    try {Invoke-Control @('--sessions',$outputId) | Add-Content -LiteralPath $report -Encoding UTF8} catch {"Optical sessions unavailable: $_" | Add-Content -LiteralPath $report}
  }
  foreach($path in @($log,($log+'.previous'),(Join-Path $root 'channel-activity.csv'),(Join-Path $root 'channel-activity.csv.previous'),$config,$statePath)) {
    if(Test-Path -LiteralPath $path){Copy-Item -LiteralPath $path -Destination $folder}
  }
  Get-Process -ErrorAction SilentlyContinue | Where-Object {$_.ProcessName -match '^(engine|NFSHeat|dirtrally2|steam|EADesktop)$'} |
    Select-Object ProcessName,Id,StartTime | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $folder 'processes.json') -Encoding UTF8
  $since=(Get-Date).AddHours(-24)
  foreach($name in @('System','Application','Microsoft-Windows-Audio/Operational','Microsoft-Windows-Audio-Glitch-Detection/Operational')) {
    try {
      $events=@(Get-WinEvent -FilterHashtable @{LogName=$name;StartTime=$since} -MaxEvents 5000 -ErrorAction Stop |
        Where-Object {$_.ProviderName -match 'Audio|Kernel-PnP|UserPnp|DriverFramework' -or
          ($_.Level -le 3 -and $_.Message -match 'audio|C-Media|VB-Audio|NFSHeat|dirtrally2|engine.exe|Samsung') } |
        Select-Object -First 1000 TimeCreated,Id,LevelDisplayName,ProviderName,Message)
      ConvertTo-Json -InputObject $events -Depth 3 | Set-Content -LiteralPath (Join-Path $folder (($name -replace '[/\\]','_')+'.json')) -Encoding UTF8
      "$name : captured $($events.Count) matching events (newest 5000 scanned, 1000 retained)." | Add-Content -LiteralPath $report
    } catch {"$name : unavailable or empty: $_" | Add-Content -LiteralPath $report}
  }
  # Native exports can be opened with Event Viewer > Action > Open Saved Log.
  $queries=@{
    System="*[System[TimeCreated[timediff(@SystemTime) <= 86400000] and (Provider[@Name='Microsoft-Windows-Kernel-PnP'] or Provider[@Name='Microsoft-Windows-UserPnp'] or Provider[@Name='Microsoft-Windows-Audio'])]]"
    Application="*[System[TimeCreated[timediff(@SystemTime) <= 86400000] and (EventID=1000 or EventID=1001 or EventID=1026)]]"
    'Microsoft-Windows-Audio/Operational'="*[System[TimeCreated[timediff(@SystemTime) <= 86400000]]]"
  }
  foreach($name in $queries.Keys) {
    $result=& wevtutil.exe epl $name (Join-Path $folder (($name -replace '[/\\]','_')+'.evtx')) ('/q:'+$queries[$name]) /ow:true 2>&1
    "$name EVTX export exit=$LASTEXITCODE $result" | Add-Content -LiteralPath $report
  }
  if($inputId) {
    & $engine --config $config --mon 2>&1 | Set-Content -LiteralPath (Join-Path $folder 'input-monitor.txt') -Encoding UTF8
    "Input monitor exit=$LASTEXITCODE" | Add-Content -LiteralPath $report
  }
  Write-Output "Diagnostics saved: $folder"
}
function Find-OwnedProcess($State) {
  if(-not $State){return $null}
  $process=Get-Process -Id $State.processId -ErrorAction SilentlyContinue
  if($process -and $process.Path -eq $engine -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$State.startedTicks){return $process}
  return $null
}
function Stop-BridgeAndRestore($State,$OwnedProcess) {
  $restoreRoles=if($State -and $State.PSObject.Properties['roles']){@($State.roles)}else{@('0','1')}
  $pending=@()
  $stopFailed=$false
  try {
    $current=@{}
    Invoke-Control @('--defaults') | ForEach-Object {if($_ -match '^([012])=(.+)$'){$current[$Matches[1]]=$Matches[2]}}
    foreach($role in $restoreRoles) {
      if($State -and $current[$role] -eq $inputId) {
        try {
          $previous=if($State.defaults -is [Collections.IDictionary]){$State.defaults[$role]}else{$State.defaults.PSObject.Properties[$role].Value}
          if(-not $previous){throw "Missing saved default for role $role"}
          Invoke-Control @('--default',$previous,$role) | Out-Null
        } catch {
          $pending+=$role
          Write-Warning "Could not restore playback role ${role}: $_"
        }
      }
    }
  } catch {
    $pending=@($restoreRoles)
    Write-Warning "Could not inspect playback defaults; retaining rollback state: $_"
  } finally {
    # Caller supplies only a launch-owned process or one verified by path and start time.
    if($OwnedProcess) {
      try {
        $OwnedProcess.Refresh()
        if(-not $OwnedProcess.HasExited){Stop-Process -Id $OwnedProcess.Id}
      } catch {$stopFailed=$true;Write-Warning "Could not stop owned encoder: $_"}
    }
  }
  try {
    if($pending.Count -or $stopFailed) {
      if($State) {
        $State | Add-Member -NotePropertyName roles -NotePropertyValue @($pending) -Force
        $State | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $statePath -Encoding UTF8
      }
    } elseif(Test-Path -LiteralPath $statePath){Remove-Item -LiteralPath $statePath}
  } catch {Write-Warning "Could not update rollback state: $_";return $false}
  return (-not $pending.Count -and -not $stopFailed)
}
$state=if(Test-Path -LiteralPath $statePath){Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json}else{$null}
$owned=Find-OwnedProcess $state
if($Action -eq 'Diagnostics') {Save-BridgeDiagnostics;exit}
if($Action -eq 'Status') {
  [pscustomobject]@{Version='0.1.9-local';Running=[bool]$owned;ProcessId=if($owned){$owned.Id}else{$null};Log=$log}
  Invoke-Control @('--defaults')
  if($inputId){Invoke-Control @('--format',$inputId)}
  exit
}
if($Action -eq 'EnableStartup') {
  $shell=New-Object -ComObject WScript.Shell
  $shortcut=$shell.CreateShortcut($startup)
  $shortcut.TargetPath=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $shortcut.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Action Start'
  $shortcut.WorkingDirectory=$root
  $shortcut.WindowStyle=7
  $shortcut.Description='Start the tested Samsung optical 5.1 encoder after sign-in'
  $shortcut.Save()
  Write-Output "Startup enabled: $startup"
  exit
}
if($Action -eq 'DisableStartup') {
  if(Test-Path -LiteralPath $startup){
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$shell.CreateShortcut($startup)
    if($shortcut.Arguments.IndexOf($PSCommandPath,[StringComparison]::OrdinalIgnoreCase) -ge 0){Remove-Item -LiteralPath $startup}
  }
  Write-Output 'Startup disabled for this installation.'
  exit
}
if($Action -eq 'Stop') {
  if(Stop-BridgeAndRestore $state $owned){Write-Output '5.1 bridge stopped; prior playback defaults restored.'}
  else {Write-Warning 'Bridge cleanup incomplete; saved rollback state retained for a later Stop retry.'}
  exit
}
if($Action -eq 'Test') {
  if(-not $outputId){throw 'Open Samsung 5.1 Setup first to select this computer''s optical output.'}
  if($owned){throw 'Stop the bridge before running its direct optical test.'}
  & $engine --config $config --tone-test
  if($LASTEXITCODE -ne 0){throw 'Optical speaker test failed.'}
  exit
}
if($owned) {
  if(Test-VirtualMix51 (Invoke-Control @('--format',$inputId))){Write-Output "5.1 bridge already running (PID $($owned.Id)).";exit}
  if(-not (Stop-BridgeAndRestore $state $owned)){throw 'Could not stop the bridge safely before repairing its speaker layout.'}
  $state=$null;$owned=$null
}
if(-not $inputId -or -not $outputId){throw 'Open Samsung 5.1 Setup first to select this computer''s audio devices.'}

# Verify the virtual input before opening optical output. Never accept stereo as gaming 5.1.
Ensure-VirtualMix51
$defaults=@{}
Invoke-Control @('--defaults') | ForEach-Object {if($_ -match '^([012])=(.+)$'){$defaults[$Matches[1]]=$Matches[2]}}
# If a previous interrupted run left the cable selected, retain its original rollback targets.
if($state){foreach($role in '0','1','2'){if($defaults[$role] -eq $inputId){$defaults[$role]=$state.defaults.PSObject.Properties[$role].Value}}}
$roles=@('0','1')
# Keep a separately selected communications headset; reroute communications only if
# it used this optical adapter, which the encoder now owns in exclusive mode.
if($defaults['2'] -eq $outputId -or $defaults['2'] -eq $inputId){$roles+='2'}
if(Test-Path -LiteralPath $log) {Copy-Item -LiteralPath $log -Destination ($log+'.previous') -Force}
[IO.File]::WriteAllText($log,"Started: $((Get-Date).ToString('o'))`r`n")
$arguments=@('--config',('"'+$config+'"'),'--require-surround','--hidden','--log',('"'+$log+'"'),'--activity-log',('"'+(Join-Path $root 'channel-activity.csv')+'"'))
$process=Start-Process -FilePath $engine -ArgumentList $arguments -WorkingDirectory $root -WindowStyle Hidden -PassThru
$newState=[pscustomobject]@{version='0.1.9-local';processId=$process.Id;startedTicks=$process.StartTime.ToUniversalTime().Ticks;defaults=$defaults;roles=$roles}
$newState | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $statePath -Encoding UTF8
try {
  $ready=$false
  for($attempt=0;$attempt -lt 30;$attempt++) {
    Start-Sleep -Milliseconds 100
    $process.Refresh()
    if($process.HasExited){throw "Encoder exited. See $log"}
    if((Get-Content -LiteralPath $log -Raw) -match 'Running\. Press Ctrl\+C'){$ready=$true;break}
  }
  if(-not $ready){throw "Encoder did not become ready. See $log"}
  foreach($role in $roles){Invoke-Control @('--default',$inputId,$role) | Out-Null}
  Write-Output "Samsung optical 5.1 running (PID $($process.Id)). Games use CABLE In 16ch."
} catch {
  $startupFailure=$_
  Stop-BridgeAndRestore $newState $process | Out-Null
  throw $startupFailure
}
