# Intentional integration test. Briefly interrupts only the configured owned bridge.
[CmdletBinding()]
param([switch]$Run,[switch]$HealthContentionOnly,[switch]$CadenceOnly,
  [ValidateRange(15,900)][int]$ObservationSeconds=180)
$ErrorActionPreference='Stop'
if(-not $Run){throw 'Use -Run during an intentional audio test; this briefly stops the owned bridge.'}
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$bridge=Join-Path $root 'Bridge.ps1'
$statePath=Join-Path $root 'bridge-state.json'
$watchPath=Join-Path $root 'supervisor-state.json'
$healthPath=Join-Path $root 'engine-health.json'
$runtime=Join-Path $root 'Runtime'
if(-not (Test-Path (Join-Path $runtime 'engine.exe'))){$runtime=Join-Path $root 'source\engine\build\Release'}
$engine=Join-Path $runtime 'engine.exe'
$control=Join-Path $runtime 'bridge_control.exe'
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Read-Json([string]$Path){Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json}
function Read-Defaults {return (@(& $control --defaults) | Sort-Object) -join "`n"}
function Test-Owned($State) {
  $process=Get-Process -Id $State.processId -ErrorAction SilentlyContinue
  return [bool]($process -and $process.Path -eq $engine -and
    $process.StartTime.ToUniversalTime().Ticks -eq [long]$State.startedTicks)
}
function Await-Recovery($Before) {
  $deadline=[datetime]::UtcNow.AddSeconds(30)
  do {
    Start-Sleep -Milliseconds 250
    try {
      $current=Read-Json $statePath;$health=Read-Json $healthPath
      if(([long]$current.startedTicks -ne [long]$Before.startedTicks) -and
        (Test-Owned $current) -and [int]$health.pid -eq [int]$current.processId -and
        $health.status -eq 'ready') {return $current}
    } catch {} # Atomic replacements can briefly be between versions.
  } while([datetime]::UtcNow -lt $deadline)
  throw 'Owned encoder did not recover with a ready heartbeat within 30 seconds.'
}
$initial=Read-Json $statePath
Assert (Test-Owned $initial) 'Begin with the configured bridge running.'
$initialDefaults=Read-Defaults
$initialVolume=(@(& $control --volume $initial.inputId)) -join "`n"
try {
  if($CadenceOnly) {
    # Read-only sustained regression: correct 48 kHz delivery must survive tab
    # switches and source pauses. Progress alone certified the old slow stream.
    $before=Read-Json $healthPath
    Assert ($null -ne $before.submittedFrames) 'Cadence verification requires v0.1.15 frame counters.'
    $deadline=[datetime]::UtcNow.AddSeconds($ObservationSeconds)
    do {
      Start-Sleep -Seconds 5
      $after=Read-Json $healthPath
      Assert (Test-Owned $initial) 'Encoder restarted or exited during cadence verification.'
      Assert ($after.pid -eq $initial.processId -and $after.status -eq 'ready') 'Encoder health is not ready.'
      Assert (([datetime]::UtcNow-([datetime]$after.updatedUtc).ToUniversalTime()).TotalSeconds -lt 5) 'Heartbeat is stale.'
      $seconds=([datetime]$after.updatedUtc-[datetime]$before.updatedUtc).TotalSeconds
      $frames=[long]$after.submittedFrames-[long]$before.submittedFrames
      $expected=$seconds*48000
      Assert ([math]::Abs($frames-$expected) -le (3072+$expected*0.005)) 'Optical delivery fell behind the 48 kHz timeline.'
      Assert ($after.droppedPackets -eq $before.droppedPackets) 'Capture packets overflowed during verification.'
      Write-Output ('Cadence: {0:N1}s, {1:N0} frames/s, drops {2}, trimmed {3}, capture discontinuities {4}' -f $seconds,($frames/$seconds),($after.droppedPackets-$before.droppedPackets),($after.trimmedFrames-$before.trimmedFrames),($after.captureDiscontinuities-$before.captureDiscontinuities))
    } while([datetime]::UtcNow -lt $deadline)
    # Listening is interactive: the user may adjust volume/mute during this
    # read-only observation. Only mutating recovery modes assert saved settings.
    Write-Output 'PASS: sustained 48 kHz optical delivery, no dropped packets or restarts.'
    return
  }
  if($HealthContentionOnly) {
    # Simulate a diagnostic/antivirus reader which denies replacement for several
    # heartbeat periods. This must not terminate healthy audio workers.
    $reader=[IO.File]::Open($healthPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {Start-Sleep -Milliseconds 2800} finally {$reader.Dispose()}
    Start-Sleep -Milliseconds 1500
    Assert (Test-Owned $initial) 'Transient health-file contention terminated healthy audio.'
    $health=Read-Json $healthPath
    Assert ([int]$health.pid -eq [int]$initial.processId -and $health.status -eq 'ready' -and
      ([datetime]::UtcNow-([datetime]$health.updatedUtc).ToUniversalTime()).TotalSeconds -lt 3) 'Health did not recover after the reader released the file.'
    Assert ((Read-Defaults) -eq $initialDefaults) 'Health contention changed playback roles.'
    Assert (((@(& $control --volume $initial.inputId)) -join "`n") -eq $initialVolume) 'Health contention changed volume or mute.'
    Write-Output 'PASS: health file locked across multiple heartbeat periods; encoder identity/settings unchanged; health publication recovered.'
    return
  }
  & $bridge -Action Start | Out-Null
  $watch=Read-Json $watchPath
  Assert ($watch.desiredRunning -eq $true) 'Automatic recovery must be enabled.'
  Assert (Test-Owned $initial) 'Idempotent Start must preserve the current encoder.'
  # Recheck the identity immediately before deliberately terminating that process.
  Assert (Test-Owned $initial) 'Never terminate a reused PID or another installation.'
  Stop-Process -Id $initial.processId -ErrorAction Stop
  $recovered=Await-Recovery $initial
  Assert ((Read-Defaults) -eq $initialDefaults) 'Recovery changed playback roles.'
  Assert (((@(& $control --volume $initial.inputId)) -join "`n") -eq $initialVolume) 'Recovery changed volume or mute.'
  & $bridge -Action Start | Out-Null
  & $bridge -Action Start | Out-Null
  $same=Read-Json $statePath
  Assert ($same.startedTicks -eq $recovered.startedTicks) 'Repeated Start created another encoder.'
  Assert ((Read-Json $watchPath).startedTicks -eq $watch.startedTicks) 'Repeated Start duplicated the watcher.'
  & $bridge -Action Stop | Out-Null
  Start-Sleep -Seconds 3
  Assert (-not (Test-Owned $recovered)) 'Stop left the owned encoder running.'
  Assert ((Read-Json $watchPath).desiredRunning -eq $false) 'Stop failed to cancel automatic recovery.'
  Assert (-not (Test-Path -LiteralPath $statePath)) 'Stop did not complete rollback.'
  Write-Output 'PASS: real owned encoder exit recovered; defaults/volume/mute preserved; repeated Start idempotent; intentional Stop stayed stopped.'
} finally {
  # Leave the user with their previously running audio route restored.
  if(-not $CadenceOnly){& $bridge -Action Start | Out-Null}
}
