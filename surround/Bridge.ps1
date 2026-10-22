<# SurroundForge bridge, v0.1.15-local. Only controls this project's encoder. #>
[CmdletBinding()]
param([ValidateSet('Start','Stop','Restart','Status','Test','Diagnostics','EnableStartup','DisableStartup','Watch')][string]$Action='Start',
  [string]$Session='',[switch]$FunctionsOnly)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$build=Join-Path $root 'Runtime'
if(-not (Test-Path -LiteralPath (Join-Path $build 'engine.exe'))){$build=Join-Path $root 'source\engine\build\Release'}
$engine=Join-Path $build 'engine.exe'
$control=Join-Path $build 'bridge_control.exe'
$config=Join-Path $root 'bridge.conf'
$statePath=Join-Path $root 'bridge-state.json'
$log=Join-Path $root 'bridge.log'
$healthPath=Join-Path $root 'engine-health.json'
$supervisorPath=Join-Path $root 'supervisor-state.json'
$supervisorLog=Join-Path $root 'supervisor.log'
$inputId=$null
$outputId=$null
if(Test-Path -LiteralPath $config) {
  foreach($line in Get-Content -LiteralPath $config) {
    if($line -match '^\s*in_id\s*=\s*(.+?)\s*$'){$inputId=$Matches[1]}
    if($line -match '^\s*out_id\s*=\s*(.+?)\s*$'){$outputId=$Matches[1]}
  }
}
$startup=Join-Path ([Environment]::GetFolderPath('Startup')) 'SurroundForge.lnk'

function Test-BridgeStartupOwner([string]$Arguments,[string]$Root) {
  if($Arguments -notmatch '(?i)(?:^|\s)-Action\s+Start(?:\s|$)'){return $false}
  if($Arguments -match '(?i)(?:^|\s)-File\s+"([^"]+)"'){$target=$Matches[1]}
  elseif($Arguments -match '(?i)(?:^|\s)-File\s+(\S+)'){$target=$Matches[1]}
  else{return $false}
  try {return [IO.Path]::GetFullPath($target) -eq [IO.Path]::GetFullPath((Join-Path $Root 'Bridge.ps1'))}
  catch {return $false}
}
function Remove-OwnedStartupShortcuts($Shell,[string]$KeepPath='') {
  # Migrate earlier shortcut names by exact script ownership, not receiver name.
  foreach($file in Get-ChildItem -LiteralPath (Split-Path $startup -Parent) -Filter '*.lnk' -File) {
    if($file.FullName -eq $KeepPath){continue}
    $link=$Shell.CreateShortcut($file.FullName)
    if(Test-BridgeStartupOwner $link.Arguments $root){Remove-Item -LiteralPath $file.FullName}
  }
}

function Invoke-BridgeNative([string]$Executable,[string[]]$Arguments,[int]$TimeoutMs=5000) {
  $process=New-Object Diagnostics.Process
  try {
    $process.StartInfo.FileName=$Executable
    $quoted=@(foreach($argument in $Arguments) {
      '"'+(([string]$argument -replace '(\\*)"','$1$1\"') -replace '(\\+)$','$1$1')+'"'
    })
    $process.StartInfo.Arguments=$quoted -join ' '
    $process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
    [void]$process.Start()
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit($TimeoutMs)) {
      $process.Kill();[void]$process.WaitForExit(1000)
      throw "Native command timed out after ${TimeoutMs}ms: $Executable"
    }
    if(-not $stdout.Wait(1000) -or -not $stderr.Wait(1000)){throw "Native command output did not close: $Executable"}
    $output=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
    if($process.ExitCode -ne 0){throw "Native command failed ($($process.ExitCode)): $Executable $($errorText.Substring(0,[Math]::Min(512,$errorText.Length)))"}
    return @($output -split '\r?\n' | Where-Object {$_ -ne ''})
  } finally {
    try {if(-not $process.HasExited){$process.Kill()}} catch {}
    $process.Dispose()
  }
}
function Invoke-Control([string[]]$Arguments) {return Invoke-BridgeNative $control $Arguments}
function Assert-BridgeRuntime {
  $versionText=(Invoke-BridgeNative $engine @('--version') 3000) -join "`n"
  if($versionText -notmatch '^SurroundForge (\d+\.\d+\.\d+)' -or [version]$Matches[1] -lt [version]'0.1.15') {
    throw 'Update the native runtime to v0.1.15 or newer before enabling automatic recovery.'
  }
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
  foreach($path in @($log,($log+'.previous'),(Join-Path $root 'channel-activity.csv'),(Join-Path $root 'channel-activity.csv.previous'),$config,$statePath,$healthPath,$supervisorPath,$supervisorLog,($supervisorLog+'.previous'))) {
    if(Test-Path -LiteralPath $path){Copy-Item -LiteralPath $path -Destination $folder}
  }
  Get-Process -ErrorAction SilentlyContinue | Where-Object {$_.ProcessName -match '^(engine|NFSHeat|dirtrally2|steam|EADesktop)$'} |
    Select-Object ProcessName,Id,StartTime | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $folder 'processes.json') -Encoding UTF8
  $since=(Get-Date).AddHours(-24)
  foreach($name in @('System','Application','Microsoft-Windows-Audio/Operational','Microsoft-Windows-Audio-Glitch-Detection/Operational')) {
    try {
      $events=@(Get-WinEvent -FilterHashtable @{LogName=$name;StartTime=$since} -MaxEvents 5000 -ErrorAction Stop |
        Where-Object {$_.ProviderName -match 'Audio|Kernel-PnP|UserPnp|DriverFramework' -or
          ($_.Level -le 3 -and $_.Message -match 'audio|C-Media|VB-Audio|NFSHeat|dirtrally2|engine.exe') } |
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
    try {Invoke-BridgeNative $engine @('--config',$config,'--mon') 10000 | Set-Content -LiteralPath (Join-Path $folder 'input-monitor.txt') -Encoding UTF8}
    catch {"Input monitor unavailable: $_" | Add-Content -LiteralPath $report}
  }
  Write-Output "Diagnostics saved: $folder"
}
function Find-OwnedProcess($State) {
  if(-not $State){return $null}
  try {
    if([int]$State.processId -le 0 -or [long]$State.startedTicks -le 0){return $null}
    $process=Get-Process -Id $State.processId -ErrorAction SilentlyContinue
    if($process -and $process.Path -eq $engine -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$State.startedTicks){return $process}
  } catch {return $null}
  return $null
}
function Stop-BridgeAndRestore($State,$OwnedProcess) {
  $restoreRoles=if($State -and $State.PSObject.Properties['roles']){@($State.roles)}else{@('0','1')}
  $boundInput=if($State -and $State.inputId){$State.inputId}else{$inputId}
  $pending=@()
  $stopFailed=$false
  try {
    $current=@{}
    Invoke-Control @('--defaults') | ForEach-Object {if($_ -match '^([012])=(.+)$'){$current[$Matches[1]]=$Matches[2]}}
    foreach($role in $restoreRoles) {
      if($State -and $current[$role] -eq $boundInput) {
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
        Write-BridgeJson $State $statePath
      }
    } elseif(Test-Path -LiteralPath $statePath){Remove-Item -LiteralPath $statePath}
  } catch {Write-Warning "Could not update rollback state: $_";return $false}
  return (-not $pending.Count -and -not $stopFailed)
}
# All lifecycle writers share a root-specific mutex. The watcher holds a second
# mutex for its lifetime; an explicit generation/desiredRunning record owns it.
function Get-BridgeObjectName([string]$Kind) {
  $sha=[Security.Cryptography.SHA256]::Create()
  try {$hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($root).ToUpperInvariant()))).Replace('-','')}
  finally {$sha.Dispose()}
  return 'Global\SurroundForge-'+$Kind+'-'+$hash
}
function New-BridgeMutex([string]$Kind) {return New-Object Threading.Mutex($false,(Get-BridgeObjectName $Kind))}
function Enter-BridgeMutex($Mutex,[int]$Timeout=30000) {
  try {return $Mutex.WaitOne($Timeout)} catch [Threading.AbandonedMutexException] {return $true}
}
function Read-BridgeJson([string]$Path) {
  if(-not (Test-Path -LiteralPath $Path)){return $null}
  try {return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json}
  catch {throw "Invalid saved bridge state: $Path. Retain it for diagnosis; no process will be claimed from it."}
}
function Read-BridgeState {
  $saved=Read-BridgeJson $statePath
  if($saved) {
    if(-not $saved.defaults -or -not $saved.PSObject.Properties['roles'] -or
       [int]$saved.processId -le 0 -or [long]$saved.startedTicks -le 0 -or
       @($saved.roles | Where-Object {$_ -notin '0','1','2'}).Count) {throw 'Invalid bridge ownership/rollback state.'}
    foreach($role in @($saved.roles)) {if(-not (Get-SavedDefault $saved $role)){throw "Missing rollback endpoint for role $role"}}
  }
  return $saved
}
function Get-SavedDefault($State,[string]$Role) {
  if($State.defaults -is [Collections.IDictionary]){return $State.defaults[$Role]}
  return $State.defaults.PSObject.Properties[$Role].Value
}
function Find-ConflictingEncoder {
  # Discovery is only a launch veto, never ownership or authority to stop it.
  # Missing/stale state must not permit a second instance to grab the same optical device.
  return @(Get-Process -Name 'engine' -ErrorAction SilentlyContinue | Where-Object {
    try {$_.Path -eq $engine} catch {$false}
  })
}
function Write-BridgeJson($Value,[string]$Path) {
  # Same-directory replacement keeps crashes/readers from observing half a JSON document.
  $next=$Path+'.next'
  $Value | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $next -Encoding UTF8
  Move-Item -LiteralPath $next -Destination $Path -Force
}
function Write-SupervisorState($Value) {
  Write-BridgeJson $Value $supervisorPath
}
function Write-SupervisorLog([string]$Message) {
  # Two bounded files; a long unplugged interval never accumulates an unbounded log.
  if((Test-Path -LiteralPath $supervisorLog) -and (Get-Item -LiteralPath $supervisorLog).Length -ge 65536) {
    Move-Item -LiteralPath $supervisorLog -Destination ($supervisorLog+'.previous') -Force
  }
  "$( [datetime]::UtcNow.ToString('o')) $Message" | Add-Content -LiteralPath $supervisorLog -Encoding UTF8
}
function Test-SupervisorIdentity($State) {
  if(-not $State){return $false}
  try {
    $process=Get-Process -Id $State.processId -ErrorAction SilentlyContinue
    if(-not $process -or $process.Path -ne $State.executable -or
       $process.StartTime.ToUniversalTime().Ticks -ne [long]$State.startedTicks -or
       [IO.Path]::GetFullPath($State.scriptPath) -ne [IO.Path]::GetFullPath((Join-Path $root 'Bridge.ps1'))){return $false}
    $command=(Get-CimInstance Win32_Process -Filter "ProcessId = $($State.processId)" -OperationTimeoutSec 3 -ErrorAction Stop).CommandLine
    if($command -notmatch '(?i)(?:^|\s)-File\s+"([^"]+)"' -or [IO.Path]::GetFullPath($Matches[1]) -ne [IO.Path]::GetFullPath($State.scriptPath)){return $false}
    return ($command -match '(?i)(?:^|\s)-Action\s+Watch(?:\s|$)' -and
      $command -match ('(?:^|\s)-Session\s+'+[regex]::Escape($State.generation)+'(?:\s|$)'))
  } catch {return $false}
}
function Disable-BridgeSupervisor {
  # Write cancellation before termination. A polling or concurrently starting watcher
  # cannot relaunch once Stop has acquired the lifecycle lock.
  $saved=try {Read-BridgeJson $supervisorPath} catch {$null}
  if($saved) {
    $saved | Add-Member NoteProperty desiredRunning $false -Force
    Write-SupervisorState $saved
    if(Test-SupervisorIdentity $saved){Stop-Process -Id $saved.processId -ErrorAction Stop}
  } else {Write-SupervisorState ([pscustomobject]@{desiredRunning=$false;generation=[guid]::NewGuid().ToString('N')})}
}
function Ensure-BridgeSupervisor($Intent=$null) {
  $saved=try {Read-BridgeJson $supervisorPath} catch {$null}
  if($saved -and $saved.desiredRunning -eq $true -and (Test-SupervisorIdentity $saved)) {
    $saved | Add-Member NoteProperty startupIntent $Intent -Force
    Write-SupervisorState $saved;return
  }
  if($saved -and (Test-SupervisorIdentity $saved)){Stop-Process -Id $saved.processId -ErrorAction Stop}
  $hostExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $generation=[guid]::NewGuid().ToString('N')
  $process=Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $root 'Bridge.ps1')+'"'),'-Action','Watch','-Session',$generation) -WorkingDirectory $root -WindowStyle Hidden -PassThru
  try {Write-SupervisorState ([pscustomobject]@{desiredRunning=$true;generation=$generation;processId=$process.Id;startedTicks=$process.StartTime.ToUniversalTime().Ticks;
    executable=$hostExe;scriptPath=(Join-Path $root 'Bridge.ps1');failures=0;nextAttemptUtc=[datetime]::UtcNow.ToString('o');healthySinceUtc=$null;lastFailure='';startupIntent=$Intent})}
  catch {Stop-Process -Id $process.Id -ErrorAction SilentlyContinue;throw}
}
function Get-RecoveryDelay([int]$Failures) {return [int][Math]::Min(60,[Math]::Pow(2,[Math]::Min(6,[Math]::Max(1,$Failures))))}
function Get-RecoveryRoles($State,$Current,[string]$VirtualId) {
  return @($State.roles | Where-Object {$Current[$_] -eq $VirtualId})
}
function Read-BridgeHealth([string]$Path=$healthPath) {
  # Readers must allow the native writer's atomic replacement on Windows.
  $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  $reader=$null
  try {$reader=[IO.StreamReader]::new($stream);return $reader.ReadToEnd() | ConvertFrom-Json}
  finally {if($reader){$reader.Dispose()}else{$stream.Dispose()}}
}
function Get-StartupRecoveryRoles($Intent,$Current) {
  return @($Intent.roles | Where-Object {$Current[$_] -eq $Intent.inputId -or $Current[$_] -eq (Get-SavedDefault $Intent $_)})
}
function New-BridgeStartupIntent($State) {
  if(-not $inputId -or -not $outputId){throw 'Open SurroundForge Setup first to select this computer''s audio devices.'}
  if($State){return [pscustomobject]@{defaults=$State.defaults;roles=@($State.roles);inputId=$inputId;outputId=$outputId}}
  $defaults=@{}
  Invoke-Control @('--defaults') | ForEach-Object {if($_ -match '^([012])=(.+)$'){$defaults[$Matches[1]]=$Matches[2]}}
  if(-not $defaults['0'] -or -not $defaults['1']){throw 'Could not save original playback defaults. Start again after Windows Audio is ready.'}
  $roles=@('0','1');if($defaults['2'] -eq $inputId -or $defaults['2'] -eq $outputId){$roles+='2'}
  return [pscustomobject]@{defaults=$defaults;roles=$roles;inputId=$inputId;outputId=$outputId}
}
function Get-BridgeHealthFailure($State,$Process,[datetime]$Now) {
  if(-not $Process){return 'encoder exited'}
  # A new process has bounded grace for first health publication.
  $age=($Now-$Process.StartTime.ToUniversalTime()).TotalSeconds
  if(-not (Test-Path -LiteralPath $healthPath)){if($age -gt 20){return 'heartbeat missing'};return $null}
  try {
    $health=Read-BridgeHealth
    if([int]$health.pid -ne $Process.Id){if($age -gt 20){return 'heartbeat belongs to another process'};return $null}
    if($health.status -eq 'failed'){return 'encoder reported failure'}
    $updated=([datetime]$health.updatedUtc).ToUniversalTime()
    if(($Now-$updated).TotalSeconds -gt 15 -or ($updated-$Now).TotalSeconds -gt 5){return 'heartbeat stale'}
    if($health.status -ne 'ready' -and $age -gt 20){return 'encoder never ready'}
  } catch {if($age -gt 20){return 'heartbeat unreadable'}}
  return $null
}
function Invoke-SupervisorStep($Supervisor,$State,[string]$Generation,[datetime]$Now) {
  if(-not $Supervisor -or $Supervisor.desiredRunning -ne $true -or $Supervisor.generation -ne $Generation){return}
  $owned=Find-OwnedProcess $State
  $failure=Get-BridgeHealthFailure $State $owned $Now
  if(-not $failure) {
    $Supervisor | Add-Member NoteProperty healthUnavailableSinceUtc $null -Force
    if(-not $Supervisor.healthySinceUtc){$Supervisor.healthySinceUtc=$Now.ToString('o');Write-SupervisorState $Supervisor}
    if($Supervisor.failures -and ($Now-([datetime]$Supervisor.healthySinceUtc).ToUniversalTime()).TotalSeconds -ge 60){$Supervisor.failures=0;$Supervisor.lastFailure='';Write-SupervisorState $Supervisor}
    return
  }
  # File replacement or antivirus sharing can transiently reject a read. Require
  # sustained unreadability; a valid but stale heartbeat still fails immediately.
  if($failure -in 'heartbeat unreadable','heartbeat missing','heartbeat belongs to another process') {
    if(-not $Supervisor.healthUnavailableSinceUtc) {
      $Supervisor | Add-Member NoteProperty healthUnavailableSinceUtc ($Now.ToString('o')) -Force
      Write-SupervisorState $Supervisor;return
    }
    if(($Now-([datetime]$Supervisor.healthUnavailableSinceUtc).ToUniversalTime()).TotalSeconds -lt 15){return}
  } else {$Supervisor | Add-Member NoteProperty healthUnavailableSinceUtc $null -Force}
  if($Now -lt ([datetime]$Supervisor.nextAttemptUtc).ToUniversalTime()){return}
  $Supervisor.healthySinceUtc=$null
  # Count unstable restarts as well as rejected launches. A device which opens
  # successfully then immediately fails must not create a two-second crash loop.
  $Supervisor.failures=[Math]::Min(100,[int]$Supervisor.failures+1)
  $Supervisor.nextAttemptUtc=$Now.AddSeconds((Get-RecoveryDelay $Supervisor.failures)).ToString('o')
  try {
    if($owned){Stop-Process -Id $owned.Id -ErrorAction Stop}
    Start-Bridge -Recovery -Intent $Supervisor.startupIntent | Out-Null
    $Supervisor | Add-Member NoteProperty startupIntent $null -Force
    Write-SupervisorLog "Recovered: $failure"
  } catch {
    $message="$failure; $_"
    if($message -ne $Supervisor.lastFailure){Write-SupervisorLog "Recovery deferred: $message"}
    $Supervisor.lastFailure=$message
  }
  Write-SupervisorState $Supervisor
}
function Start-Bridge([switch]$Recovery,$Intent=$null) {
  Assert-BridgeRuntime
  $state=Read-BridgeState
  $owned=Find-OwnedProcess $state
  if(-not $owned -and @(Find-ConflictingEncoder).Count){throw 'An encoder from this installation is running without matching ownership state. Refusing a duplicate launch; retain state for diagnosis.'}
  if(-not $inputId -or -not $outputId){throw 'Open SurroundForge Setup first to select this computer''s audio devices.'}
  if($Intent -and ($Intent.inputId -ne $inputId -or $Intent.outputId -ne $outputId)){throw 'Startup device configuration changed; Stop and Start to apply it safely.'}
  # The watcher keeps its original IDs. Refuse to launch a modified config that
  # would silently use different devices with those saved rollback targets.
  $configuredInput=$null;$configuredOutput=$null
  foreach($line in Get-Content -LiteralPath $config) {
    if($line -match '^\s*in_id\s*=\s*(.+?)\s*$'){$configuredInput=$Matches[1]}
    if($line -match '^\s*out_id\s*=\s*(.+?)\s*$'){$configuredOutput=$Matches[1]}
  }
  if($configuredInput -ne $inputId -or $configuredOutput -ne $outputId -or
     (($Recovery -or $owned) -and $state -and (($state.inputId -and $state.inputId -ne $inputId) -or ($state.outputId -and $state.outputId -ne $outputId)))) {throw 'Device configuration changed; Stop and Start to apply it safely.'}
  if($owned) {
    if(Test-VirtualMix51 (Invoke-Control @('--format',$inputId))){Write-Output "5.1 bridge already running (PID $($owned.Id)).";return}
    if(-not (Stop-BridgeAndRestore $state $owned)){throw 'Could not stop the bridge safely before repairing its speaker layout.'}
    $state=$null
  }
  Ensure-VirtualMix51
  $current=@{}
  Invoke-Control @('--defaults') | ForEach-Object {if($_ -match '^([012])=(.+)$'){$current[$Matches[1]]=$Matches[2]}}
  $defaults=@{};foreach($role in '0','1','2'){$defaults[$role]=$current[$role]}
  if($state){foreach($role in '0','1','2'){if($defaults[$role] -eq $inputId){$defaults[$role]=Get-SavedDefault $state $role}}}
  $roles=@('0','1')
  if($defaults['2'] -eq $outputId -or $defaults['2'] -eq $inputId){$roles+='2'}
  if($Recovery -and $state){$defaults=$state.defaults;$roles=@($state.roles)}
  if($Recovery -and $Intent){$defaults=$Intent.defaults;$roles=@($Intent.roles)}
  $routeRoles=if($Recovery -and $Intent){@(Get-StartupRecoveryRoles $Intent $current)}elseif($Recovery -and $state){@(Get-RecoveryRoles $state $current $inputId)}else{$roles}
  if(Test-Path -LiteralPath $log){Copy-Item -LiteralPath $log -Destination ($log+'.previous') -Force}
  [IO.File]::WriteAllText($log,"Started: $((Get-Date).ToString('o'))`r`n")
  if(Test-Path -LiteralPath $healthPath){Remove-Item -LiteralPath $healthPath}
  $arguments=@('--config',('"'+$config+'"'),'--require-surround','--hidden','--log',('"'+$log+'"'),'--activity-log',('"'+(Join-Path $root 'channel-activity.csv')+'"'),'--health-log',('"'+$healthPath+'"'))
  $process=Start-Process -FilePath $engine -ArgumentList $arguments -WorkingDirectory $root -WindowStyle Hidden -PassThru
  $newState=[pscustomobject]@{version='0.1.15-local';processId=$process.Id;startedTicks=$process.StartTime.ToUniversalTime().Ticks;defaults=$defaults;roles=$roles;inputId=$inputId;outputId=$outputId}
  try {
    Write-BridgeJson $newState $statePath
    $ready=$false
    for($attempt=0;$attempt -lt 50;$attempt++) {
      Start-Sleep -Milliseconds 100
      $process.Refresh()
      if($process.HasExited){throw "Encoder exited. See $log"}
      if((Get-Content -LiteralPath $log -Raw) -match 'Running\. Press Ctrl\+C'){$ready=$true;break}
    }
    if(-not $ready){throw "Encoder did not become ready. See $log"}
    foreach($role in $routeRoles){Invoke-Control @('--default',$inputId,$role) | Out-Null}
    Write-Output "SurroundForge running (PID $($process.Id)). Games use the configured virtual 5.1 input."
  } catch {
    $startupFailure=$_
    if($Recovery) {Stop-Process -Id $process.Id -ErrorAction SilentlyContinue}
    else {Stop-BridgeAndRestore $newState $process | Out-Null}
    throw $startupFailure
  }
}

function Get-BridgeSnapshot {
  try {
    $saved=if(Test-Path -LiteralPath $statePath){Read-BridgeHealth $statePath}else{$null}
    $process=Find-OwnedProcess $saved
    $watch=if(Test-Path -LiteralPath $supervisorPath){Read-BridgeHealth $supervisorPath}else{$null}
    $health=if(Test-Path -LiteralPath $healthPath){Read-BridgeHealth}else{$null}
    return [pscustomobject]@{Running=[bool]$process;ProcessId=if($process){$process.Id}else{0};
      Supervised=[bool]($watch -and $watch.desiredRunning -eq $true -and (Test-SupervisorIdentity $watch));
      Health=$health;Error='';Version='0.1.16'}
  } catch {return [pscustomobject]@{Running=$false;ProcessId=0;Supervised=$false;Health=$null;Error="$($_)";Version='0.1.16'}}
}
function Ensure-BridgeTray {
  $tray=Join-Path $root 'Tray.ps1'
  if(-not (Test-Path -LiteralPath $tray)){return}
  try {
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$tray+'"'),'-Show') -WorkingDirectory $root | Out-Null
  } catch {Write-Warning "Audio is available, but the status icon could not start: $_"}
}
function Restart-Bridge {
  # Caller holds the lifecycle mutex. Keep rollback state and current default
  # choices intact; use the same ownership/recovery path as the supervisor.
  Assert-BridgeRuntime
  $saved=Read-BridgeState
  $intent=New-BridgeStartupIntent $saved
  $process=Find-OwnedProcess $saved
  Disable-BridgeSupervisor
  try {
    if($process) {Stop-Process -Id $process.Id -ErrorAction Stop;if(-not $process.WaitForExit(5000)){throw 'The owned encoder did not stop within five seconds.'}}
    Start-Bridge -Recovery -Intent $intent
    Ensure-BridgeSupervisor
  } catch {
    Ensure-BridgeSupervisor -Intent $intent
    throw "Restart needs attention; automatic recovery will retry. $($_)"
  }
}

if($FunctionsOnly){return}
if($Action -eq 'Watch') {
  if($Session -notmatch '^[a-f0-9]{32}$'){throw 'Watch requires an owned session.'}
  $watchMutex=New-BridgeMutex 'watch'
  # An obsolete watcher may still hold the lifetime mutex while waiting for the
  # action lock that launched us. Give it time to observe the new generation.
  if(-not (Enter-BridgeMutex $watchMutex 30000)){$watchMutex.Dispose();exit}
  try {
    while($true) {
      $gate=New-BridgeMutex 'action';$locked=$false
      try {
        $locked=Enter-BridgeMutex $gate
        if(-not $locked){throw 'Lifecycle action busy'}
        $supervisor=Read-BridgeJson $supervisorPath
        if(-not $supervisor -or $supervisor.desiredRunning -ne $true -or $supervisor.generation -ne $Session){break}
        try {Invoke-SupervisorStep $supervisor (Read-BridgeState) $Session ([datetime]::UtcNow)}
        catch {if($supervisor.lastFailure -ne "$($_)"){$supervisor.lastFailure="$_";Write-SupervisorState $supervisor;Write-SupervisorLog "Ownership/state check deferred: $_"}}
      } catch {Write-SupervisorLog "Supervisor check deferred: $_"}
      finally {if($locked){$gate.ReleaseMutex()};$gate.Dispose()}
      Start-Sleep -Seconds 2
    }
  } finally {$watchMutex.ReleaseMutex();$watchMutex.Dispose()}
  exit
}

if($Action -eq 'Diagnostics'){Save-BridgeDiagnostics;exit}
$gate=New-BridgeMutex 'action';$locked=Enter-BridgeMutex $gate
if(-not $locked){$gate.Dispose();throw 'Another bridge action is still busy. Try again shortly.'}
try {
  if($Action -eq 'Restart'){Restart-Bridge;Ensure-BridgeTray;exit}
  if($Action -eq 'EnableStartup') {
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$shell.CreateShortcut($startup)
    if((Test-Path -LiteralPath $startup) -and -not (Test-BridgeStartupOwner $shortcut.Arguments $root)){throw 'The SurroundForge startup shortcut belongs to another installation. Disable startup there first.'}
    $shortcut.TargetPath=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shortcut.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Action Start'
    $shortcut.WorkingDirectory=$root;$shortcut.WindowStyle=7
    $shortcut.IconLocation=Join-Path $env:LOCALAPPDATA 'SurroundForge\surroundforge.ico,0'
    $shortcut.Description='Start the tested SurroundForge encoder after sign-in'
    $shortcut.Save();Remove-OwnedStartupShortcuts $shell $startup
    Write-Output "Startup enabled: $startup";exit
  }
  if($Action -eq 'DisableStartup') {
    Disable-BridgeSupervisor
    $shell=New-Object -ComObject WScript.Shell;Remove-OwnedStartupShortcuts $shell
    Write-Output 'Startup and automatic recovery disabled for this installation; current audio continues.';exit
  }
  # Cancellation must happen even when rollback JSON is damaged.
  if($Action -eq 'Stop'){Disable-BridgeSupervisor}
  $state=Read-BridgeState;$owned=Find-OwnedProcess $state
  if($Action -eq 'Status') {
    $supervisor=try {Read-BridgeJson $supervisorPath} catch {$null}
    [pscustomobject]@{Version='0.1.15-local';Running=[bool]$owned;ProcessId=if($owned){$owned.Id}else{$null};
      Supervised=[bool]($supervisor -and $supervisor.desiredRunning -eq $true -and (Test-SupervisorIdentity $supervisor));Log=$log;Health=try {Read-BridgeHealth} catch {$null}}
    Invoke-Control @('--defaults');if($inputId){Invoke-Control @('--format',$inputId)};exit
  }
  if($Action -eq 'Stop') {
    if(Stop-BridgeAndRestore $state $owned){Write-Output '5.1 bridge stopped; prior playback defaults restored.'}
    else {Write-Warning 'Bridge cleanup incomplete; saved rollback state retained for a later Stop retry.'}
    exit
  }
  if($Action -eq 'Test') {
    if(-not $outputId){throw 'Open SurroundForge Setup first to select this computer''s optical output.'}
    if($owned){throw 'Stop the bridge before running its direct optical test.'}
    & $engine --config $config --tone-test
    if($LASTEXITCODE -ne 0){throw 'Optical speaker test failed.'};exit
  }
  Assert-BridgeRuntime
  $intent=New-BridgeStartupIntent $state
  try {Start-Bridge}
  catch {
    Ensure-BridgeSupervisor -Intent $intent
    Write-SupervisorLog "Initial startup deferred: $_"
    Write-Warning "Audio startup is pending; the supervisor will retry with bounded backoff: $_"
    Ensure-BridgeTray
    exit
  }
  Ensure-BridgeSupervisor
  Ensure-BridgeTray
} finally {$gate.ReleaseMutex();$gate.Dispose()}
