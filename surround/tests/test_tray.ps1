# Pure status and mocked lifecycle regression. Never touches live audio or starts UI.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$script:assertions=0
function Assert($Condition,[string]$Message) {
  $script:assertions++
  if(-not $Condition){throw $Message}
}
function Start-Process {throw 'Import unexpectedly started a process'}
function Stop-Process {throw 'Import unexpectedly stopped a process'}
. (Join-Path $PSScriptRoot '..\Bridge.ps1') -FunctionsOnly
. (Join-Path $PSScriptRoot '..\Tray.ps1') -NoUi
Assert ([bool](Get-Command Get-TrayStatus)) 'NoUi import must expose status without dispatching Start'
Assert (-not $script:TrayUi) 'NoUi import must not construct UI'
$now=([datetime]'2026-10-10T20:00:00Z').ToUniversalTime()
function New-Health([long]$Frames=480000,[long]$Drops=170,[int]$ProcessId=41,[int]$Age=0) {
  [pscustomobject]@{pid=$ProcessId;status='ready';updatedUtc=$now.AddSeconds(-$Age).ToString('o');submittedFrames=$Frames;droppedPackets=$Drops;capturePolls=0;underruns=3}
}
function New-Snapshot($Health=(New-Health),[bool]$Running=$true,[bool]$Supervised=$true) {
  [pscustomobject]@{Running=$Running;ProcessId=41;Supervised=$Supervised;Health=$Health;Error=''}
}
$previous=New-Health -Frames 0 -Age 10
$status=Get-TrayStatus (New-Snapshot) $previous $now
Assert ($status.Label -eq 'Running' -and $status.Tone -eq 'Green' -and $status.Rate -eq 48000) '48k delivery and old cumulative drops must remain green'
Assert ($status.Detail -match 'No new packet drops') 'Timing-confirmed status must explain packet health'
$status=Get-TrayStatus (New-Snapshot (New-Health -Frames 438528)) $previous $now
Assert ($status.Label -eq 'Needs attention' -and $status.Tone -eq 'Amber') 'Ready heartbeat with slow carrier must not appear healthy'
$status=Get-TrayStatus (New-Snapshot (New-Health -Drops 171)) $previous $now
Assert ($status.Label -eq 'Needs attention') 'New dropped packets must surface'
$status=Get-TrayStatus (New-Snapshot) $null $now
Assert ($status.Label -eq 'Running' -and $status.Rate -eq $null) 'Silent ready source is healthy while timing sample accumulates'
Assert ((Get-TrayStatus (New-Snapshot $null $false $false) $null $now).Label -eq 'Stopped') 'Unsupervised stopped engine must say Stopped'
Assert ((Get-TrayStatus (New-Snapshot $null $false $true) $null $now).Label -eq 'Recovering') 'Supervised stopped engine must say Recovering'
Assert ((Get-TrayStatus (New-Snapshot (New-Health -Age 6)) $null $now).Label -eq 'Needs attention') 'Stale heartbeat must surface'
Assert ((Get-TrayStatus (New-Snapshot (New-Health -ProcessId 99)) $null $now).Label -eq 'Starting') 'Wrong PID cannot certify current engine'
$bad=New-Snapshot;$bad.Error='fixture read failed'
Assert ((Get-TrayStatus $bad $null $now).Tone -eq 'Red') 'Snapshot read error must surface'

# Exercise production ownership and intent helpers, mocking only host operations.
function Assert-BridgeRuntime {}
function Read-BridgeState {return $script:fixtureState}
function Get-Process {param($Id,$ErrorAction) return $script:fixtureProcess}
function Disable-BridgeSupervisor {$script:events.Add('disable')}
function Stop-Process {param($Id,$ErrorAction) $script:events.Add('stop');$script:stoppedIds.Add([int]$Id)}
function Start-Bridge {
  param([switch]$Recovery,$Intent)
  $script:events.Add('start');$script:receivedIntent=$Intent;$script:receivedRecovery=[bool]$Recovery
  if($script:failStart){throw 'fixture USB unavailable'}
}
function Ensure-BridgeSupervisor {
  param($Intent=$null)
  $script:events.Add('supervise');$script:retryIntent=$Intent
}
function Reset-Fixture {
  $script:events=New-Object 'System.Collections.Generic.List[string]'
  $script:stoppedIds=New-Object 'System.Collections.Generic.List[int]'
  $script:fixtureProcess=[pscustomobject]@{Id=41;Path=$engine;StartTime=$now.AddSeconds(-30)}
  $script:fixtureProcess | Add-Member ScriptMethod WaitForExit {param($Milliseconds) $script:events.Add('wait');return $true}
  $script:fixtureState=[pscustomobject]@{processId=41;startedTicks=$script:fixtureProcess.StartTime.ToUniversalTime().Ticks;defaults=[pscustomobject]@{'0'='original';'1'='headset';'2'='communications'};roles=@('0','1')}
  $script:failStart=$false;$script:receivedIntent=$null;$script:retryIntent=$null;$script:receivedRecovery=$false
}
$inputId='fixture-input';$outputId='fixture-output'
Reset-Fixture
Restart-Bridge
Assert (($events -join ',') -eq 'disable,stop,wait,start,supervise') 'Restart must disable watcher before owned stop and await exit before start'
Assert ($stoppedIds.Count -eq 1 -and $stoppedIds[0] -eq 41) 'Restart stops only the verified owned process'
Assert ($receivedRecovery -and $receivedIntent.inputId -eq $inputId -and $receivedIntent.outputId -eq $outputId) 'Restart must use recovery mode and current endpoint intent'
Assert ($receivedIntent.defaults.'0' -eq 'original' -and $receivedIntent.defaults.'1' -eq 'headset' -and ($receivedIntent.roles -join ',') -eq '0,1') 'Restart preserves original rollback defaults and roles'
foreach($ownership in @('wrong-path','reused-pid','exited')) {
  Reset-Fixture
  switch($ownership) {
    'wrong-path' {$fixtureProcess.Path='E:\fixture\unrelated.exe'}
    'reused-pid' {$fixtureProcess.StartTime=$now}
    'exited' {$fixtureProcess=$null}
  }
  Restart-Bridge
  Assert ($stoppedIds.Count -eq 0) "Restart must not stop $ownership process"
  Assert (($events -join ',') -eq 'disable,start,supervise') "Restart must recover safely from $ownership"
}
Reset-Fixture;$failStart=$true;$caught=$false
try {Restart-Bridge} catch {$caught=$true}
Assert $caught 'Start failure must reach caller'
Assert (($events -join ',') -eq 'disable,stop,wait,start,supervise') 'Start failure must re-enable owned supervision'
Assert ($retryIntent.inputId -eq $inputId -and $retryIntent.defaults.'1' -eq 'headset') 'Failed restart must retain exact recovery intent'
Write-Output "PASS: tray status and mocked restart ($assertions assertions); no live audio changes."
