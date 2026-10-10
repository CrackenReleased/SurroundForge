# Mock-only tests of the actual supervisor helpers. Never starts or stops live audio.
[CmdletBinding()]
param([string]$BridgePath='')
if(-not $BridgePath){$BridgePath=Join-Path $PSScriptRoot '..\Bridge.ps1'}
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($BridgePath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0]}
foreach($name in 'Find-OwnedProcess','Get-BridgeHealthFailure','Get-RecoveryDelay','Get-RecoveryRoles','Test-SupervisorIdentity','Invoke-SupervisorStep','Disable-BridgeSupervisor','Read-BridgeJson','Read-BridgeState','Get-SavedDefault','Get-BridgeObjectName','New-BridgeMutex','Enter-BridgeMutex') {
  $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
  if(-not $fn){throw "Missing resilience helper: $name"}
  Invoke-Expression $fn.Extent.Text
}
function Assert($condition,$message){if(-not $condition){throw $message}}
function Get-Process {param($Id,$ErrorAction) $script:fake}
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) [pscustomobject]@{CommandLine=$script:command}}
function Get-Content {param($LiteralPath,[switch]$Raw) if($script:badHealth){throw 'partial write'};return $script:healthJson}
function Read-BridgeHealth {if($script:badHealth){throw 'sharing violation'};return $script:healthJson | ConvertFrom-Json}
function Test-Path {param($LiteralPath) $script:healthExists}
function Start-Bridge {param([switch]$Recovery,$Intent) $script:starts++;if($script:launchFails){throw 'USB disconnected'}}
function Stop-Process {param($Id,$Force,$ErrorAction) $script:stops++}
function Write-SupervisorState {param($Value) $script:saved=$Value}
function Write-SupervisorLog {param($Message) $script:messages+=$Message}
$engine='E:\fixture\engine.exe';$root='E:\fixture';$healthPath='health';$PSCommandPath='E:\fixture\Bridge.ps1'
$script:now=([datetime]'2026-10-10T12:00:00Z').ToUniversalTime()
function Reset-Fixture {
  $script:fake=[pscustomobject]@{Id=41;Path=$engine;StartTime=$script:now.AddSeconds(-30);HasExited=$false}
  $script:state=[pscustomobject]@{processId=41;startedTicks=$script:fake.StartTime.Ticks;defaults=[pscustomobject]@{'0'='optical';'1'='speaker';'2'='headset'};roles=@('0','1')}
  $script:supervisor=[pscustomobject]@{desiredRunning=$true;generation='run';failures=0;nextAttemptUtc=$script:now.ToString('o');healthySinceUtc=$null;lastFailure=''}
  $script:healthExists=$true;$script:badHealth=$false;$script:healthJson=(@{pid=41;status='ready';updatedUtc=$script:now.ToString('o');renderCycles=20;capturePolls=0}|ConvertTo-Json)
  $script:launchFails=$false;$script:starts=0;$script:stops=0;$script:messages=@();$script:saved=$null
}
Reset-Fixture
Assert (-not (Get-BridgeHealthFailure $state $fake $now)) 'Source silence (zero capture packets) must remain healthy'
$healthJson=(@{pid=41;status='ready';updatedUtc=$now.AddSeconds(-16).ToString('o')}|ConvertTo-Json)
Assert ((Get-BridgeHealthFailure $state $fake $now) -eq 'heartbeat stale') 'Hung main loop must be detected'
Invoke-SupervisorStep $supervisor $state 'run' $now
Assert ($stops -eq 1 -and $starts -eq 1) 'Stale heartbeat must stop only owned engine and recover'
Reset-Fixture
$fake=$null
Invoke-SupervisorStep $supervisor $state 'run' $now
Assert ($starts -eq 1 -and $stops -eq 0) 'Exited process must recover without killing another process'
Invoke-SupervisorStep $supervisor $state 'run' $now.AddSeconds(2)
Assert ($starts -eq 2 -and $supervisor.failures -eq 2 -and ([datetime]$supervisor.nextAttemptUtc).ToUniversalTime() -eq $now.AddSeconds(6)) 'Repeated successful launches followed by death must also back off'
Reset-Fixture
$fake.Path='E:\other\engine.exe';$launchFails=$true
Invoke-SupervisorStep $supervisor $state 'run' $now
Assert ($stops -eq 0 -and $starts -eq 1 -and $supervisor.failures -eq 1) 'Reused PID must never be killed'
Assert (([datetime]$supervisor.nextAttemptUtc).ToUniversalTime() -gt $now) 'Failed launch must back off'
Invoke-SupervisorStep $supervisor $state 'run' $now.AddSeconds(1)
Assert ($starts -eq 1) 'No retry before deadline'
Assert ((Get-RecoveryDelay 10) -eq 60 -and (Get-RecoveryDelay 1) -eq 2) 'Exponential retries must cap at 60s'
Reset-Fixture
$supervisor.desiredRunning=$false;$fake=$null
Invoke-SupervisorStep $supervisor $state 'run' $now
Assert ($starts -eq 0 -and $stops -eq 0) 'Intentional Stop/Disable must never resurrect encoder'
$supervisor.desiredRunning=$true
Invoke-SupervisorStep $supervisor $state 'old-run' $now
Assert ($starts -eq 0) 'Obsolete watcher generation must not revive encoder'
Reset-Fixture
$fake.StartTime=$now.AddSeconds(-5);$state.startedTicks=$fake.StartTime.Ticks;$healthExists=$false
Assert (-not (Get-BridgeHealthFailure $state $fake $now)) 'Fresh launch needs bounded heartbeat grace'
$fake.StartTime=$now.AddSeconds(-30);$state.startedTicks=$fake.StartTime.Ticks
Assert ((Get-BridgeHealthFailure $state $fake $now) -eq 'heartbeat missing') 'Missing health cannot hide a stall forever'
$healthExists=$true;$badHealth=$true
Assert ((Get-BridgeHealthFailure $state $fake $now) -eq 'heartbeat unreadable') 'Corrupt heartbeat must remain recoverable'
Invoke-SupervisorStep $supervisor $state 'run' $now
Assert ($starts -eq 0 -and $stops -eq 0) 'One sharing/read failure must not stop healthy audio'
Invoke-SupervisorStep $supervisor $state 'run' $now.AddSeconds(16)
Assert ($starts -eq 1 -and $stops -eq 1) 'Sustained unreadability must not mask failed health indefinitely'
$badHealth=$false;$healthJson=(@{pid=999;status='ready';updatedUtc=$now.ToString('o')}|ConvertTo-Json)
Assert ((Get-BridgeHealthFailure $state $fake $now) -eq 'heartbeat belongs to another process') 'Old health must not bless reused PID'
Assert (@(Get-RecoveryRoles $state @{'0'='virtual';'1'='manual';'2'='headset'} 'virtual').Count -eq 1) 'Recovery preserves manual default/headset'
$fake.Path='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$supervisor | Add-Member NoteProperty processId 41
$supervisor | Add-Member NoteProperty startedTicks $fake.StartTime.Ticks
$supervisor | Add-Member NoteProperty executable $fake.Path
$supervisor | Add-Member NoteProperty scriptPath 'E:\fixture\Bridge.ps1'
$command='powershell -File "E:\fixture\Bridge.ps1" -Action Watch -Session run'
Assert (Test-SupervisorIdentity $supervisor) 'Exact script/process identity must match'
$command='powershell -File "E:\other\Bridge.ps1" -Action Watch -Session run'
Assert (-not (Test-SupervisorIdentity $supervisor)) 'Different script must not count as owned'
$badHealth=$true;$caught=$false
try {Read-BridgeState | Out-Null} catch {$caught=$true}
Assert $caught 'Corrupt saved JSON must fail closed before a process can be claimed'
function Read-BridgeJson {param($Path) $script:supervisor}
$command='powershell -File "E:\fixture\Bridge.ps1" -Action Watch -Session run';$stops=0
Disable-BridgeSupervisor
Assert (-not $saved.desiredRunning -and $stops -eq 1) 'Disable must cancel before stopping exact owned watcher'
$supervisor.desiredRunning=$true;$command='powershell -File "E:\other\Bridge.ps1" -Action Watch -Session run';$stops=0
Disable-BridgeSupervisor
Assert (-not $saved.desiredRunning -and $stops -eq 0) 'Disable must leave unrelated/reused watcher PID alone'
# Exercise cross-thread named lifecycle ownership with real mutexes, no processes/audio.
$mutex=New-BridgeMutex 'action';Assert (Enter-BridgeMutex $mutex 0) 'First lifecycle owner must acquire lock'
$probe=[powershell]::Create()
try {
  $objHelper=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-BridgeObjectName'},$true).Extent.Text
  $mutexName=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-BridgeMutex'},$true).Extent.Text
  [void]$probe.AddScript('param($RootValue,$ObjDef,$Definition) $root=$RootValue; Invoke-Expression $ObjDef; Invoke-Expression $Definition; $other=New-BridgeMutex action; try {$acquired=$other.WaitOne(0); if($acquired){$other.ReleaseMutex()}; return $acquired} finally {$other.Dispose()}').AddArgument($root).AddArgument($objHelper).AddArgument($mutexName)
  $result=$probe.Invoke()
  Assert (-not $result[0]) 'Concurrent Start/Stop/Watch actions must not overlap ownership'
} finally {$probe.Dispose();$mutex.ReleaseMutex();$mutex.Dispose()}
Write-Output 'PASS: death/stall, silence/mute, bounded recovery/backoff, Stop/generation, PID/script ownership and manual defaults'

# Native command bounding and runtime/startup gates use production helpers too.
foreach($name in 'Invoke-BridgeNative','Assert-BridgeRuntime','Get-StartupRecoveryRoles') {
  $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
  if(-not $fn){throw "Missing bounded startup helper: $name"}
  Invoke-Expression $fn.Extent.Text
}
$testHost=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$result=Invoke-BridgeNative $testHost @('-NoProfile','-NonInteractive','-Command',"'native fixture output'; exit 0")
Assert ($result -contains 'native fixture output') 'Bounded native call must retain output'
$caught=$false
try {Invoke-BridgeNative $testHost @('-NoProfile','-NonInteractive','-Command','exit 7') | Out-Null} catch {$caught=$true}
Assert $caught 'Native command failure must propagate'
$timer=[Diagnostics.Stopwatch]::StartNew();$caught=$false
try {Invoke-BridgeNative $testHost @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 10') 100 | Out-Null} catch {$caught=$true}
$timer.Stop()
Assert ($caught -and $timer.Elapsed.TotalSeconds -lt 3) 'Hung native call must be killed within its bounded deadline'
function Invoke-BridgeNative {param($Executable,$Arguments,$TimeoutMs) if($script:versionFails){throw 'version query failed'};return $script:versionText}
foreach($versionText in 'SurroundForge 0.1.15-local','SurroundForge 0.1.16-local') {Assert-BridgeRuntime}
foreach($versionText in 'SurroundForge 0.1.12-local','SurroundForge 0.1.13-local','SurroundForge 0.1.14-local','invalid version') {
  $caught=$false;try {Assert-BridgeRuntime} catch {$caught=$true};Assert $caught 'Incompatible runtime must not start a watcher'
}
$versionFails=$true;$caught=$false;try {Assert-BridgeRuntime} catch {$caught=$true};Assert $caught 'Unreadable runtime version must fail closed'
$intent=[pscustomobject]@{defaults=[pscustomobject]@{'0'='speaker';'1'='speaker';'2'='headset'};roles=@('0','1');inputId='virtual';outputId='optical'}
$route=@(Get-StartupRecoveryRoles $intent @{'0'='speaker';'1'='manual';'2'='headset'})
Assert ($route.Count -eq 1 -and $route[0] -eq '0') 'Delayed first startup must preserve a manual output change'
Reset-Fixture;$fake=$null;$supervisor | Add-Member NoteProperty startupIntent $intent
Invoke-SupervisorStep $supervisor $null 'run' $now
Assert ($starts -eq 1 -and -not $supervisor.startupIntent) 'Successful delayed startup must consume pending intent'
Write-Output 'PASS: bounded native calls, runtime compatibility and delayed startup role preservation'

# Replace the file while the real reader's conversion pipeline still holds it.
& {
  $readerFunction=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-BridgeHealth'},$true)
  if(-not $readerFunction){throw 'Missing replacement-safe health reader'}
  Invoke-Expression $readerFunction.Extent.Text
  $healthPath=Join-Path $PSScriptRoot ('output/health-reader-'+[guid]::NewGuid().ToString('N')+'.json')
  $replacement=$healthPath+'.next'
  [IO.Directory]::CreateDirectory((Split-Path $healthPath -Parent)) | Out-Null
  function ConvertFrom-Json {
    param([Parameter(ValueFromPipeline=$true)][string]$InputObject)
    process {
      [IO.File]::Replace($replacement,$healthPath,[NullString]::Value)
      Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject
    }
  }
  try {
    [IO.File]::WriteAllText($healthPath,'{"pid":41,"status":"ready"}')
    [IO.File]::WriteAllText($replacement,'{"pid":42,"status":"ready"}')
    $snapshot=Read-BridgeHealth
    Assert ($snapshot.pid -eq 41) 'Reader must retain a complete consistent snapshot during replacement'
    Assert ([IO.File]::ReadAllText($healthPath).Contains('42')) 'Open health reader must allow atomic replacement'
  } finally {[IO.File]::Delete($healthPath);[IO.File]::Delete($replacement)}
}
Write-Output 'PASS: production health reader permits atomic replacement while its stream is open'



