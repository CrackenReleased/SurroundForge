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
$recovering=New-Snapshot $null $false $true
$recovering | Add-Member NoteProperty Failure 'Optical device unavailable'
Assert ((Get-TrayStatus $recovering $null $now).Detail -match 'Optical device unavailable') 'Recovering UI must explain the recorded device failure'
$recovering.Failure='F' * 250
Assert ((Get-TrayStatus $recovering $null $now).Detail.Length -le 145) 'A long recovery error must fit the controller detail area'
Assert ((Get-TrayStatus (New-Snapshot (New-Health -Age 6)) $null $now).Label -eq 'Needs attention') 'Stale heartbeat must surface'
Assert ((Get-TrayStatus (New-Snapshot (New-Health -ProcessId 99)) $null $now).Label -eq 'Starting') 'Wrong PID cannot certify current engine'
$bad=New-Snapshot;$bad.Error='fixture read failed'
Assert ((Get-TrayStatus $bad $null $now).Tone -eq 'Red') 'Snapshot read error must surface'
Assert ((Get-TrayStatus $bad $null $now).Detail -match 'fixture read failed') 'Offline controller status must include its recorded read error'

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
$traySource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Tray.ps1') -Raw
Assert ($traySource -match 'FillPolygon' -and $traySource -match 'DrawArc' -and $traySource -notmatch 'DrawString\("S"') 'Tray icon must render the custom Sonic Anvil vector logo rather than a generic letter S'
Assert ($traySource -match 'Green=\[Drawing\.Color\]::FromArgb\(0,228,196\)' -and $traySource -match 'Amber=\[Drawing\.Color\]::FromArgb\(250,160,10\)' -and $traySource -match 'Gray=\[Drawing\.Color]::FromArgb\(130,145,165\)' -and $traySource -match 'Red=\[Drawing\.Color]::FromArgb\(248,65,75\)') 'Controller must configure teal for on, orange for issues, gray for stopped, and red for off'
Assert ($traySource -match 'if\(\$script:TrayUi\.LogoBox\)\{\$script:TrayUi\.LogoBox\.Image=\$script:TrayBitmaps\[\$status\.Tone\]\}') 'Update-TrayUi must dynamically update logo box image based on status tone'
Assert ($traySource -match '\$script:TrayUi\.Form\.Icon=\$script:TrayIcons\[\$status\.Tone\]') 'Update-TrayUi must dynamically update window icon based on status tone'
Assert ($traySource -match '\$script:TrayUi\.Icon\.Icon=\$script:TrayIcons\[\$status\.Tone\]') 'Update-TrayUi must dynamically update notification tray icon based on status tone'
$bridgeSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Bridge.ps1') -Raw
Assert ($bridgeSource -match 'IconLocation=Join-Path \$env:LOCALAPPDATA ''SurroundForge\\surroundforge\.ico,0''') 'Startup shortcut must link to canonical surroundforge.ico'
Assert ($traySource -match 'Stop audio & close') 'Tray controller must provide a Stop audio & close action to stop the engine and exit cleanly'
Assert ($traySource -match 'EnsureDefaultDesktop' -and $traySource -match 'SurroundForge_Tray_Launch' -and $traySource -match 'Ensure-SurroundForgeHost') 'Tray controller must relaunch via SurroundForge.exe onto Default desktop with Sonic Anvil Win32 icon'
Assert ((Get-TrayLaunchMode 'Default' 'powershell') -eq 'Direct') 'A normal desktop shortcut must launch the GUI host directly rather than through Task Scheduler'
Assert ((Get-TrayLaunchMode 'Default' 'SurroundForge') -eq 'InProcess') 'The GUI host must not relaunch itself'
Assert ((Get-TrayLaunchMode 'isolated-agent-desktop' 'powershell') -eq 'Scheduled') 'An isolated desktop must still reach the visible desktop'
$hostCommand=Get-Command Ensure-SurroundForgeHost
Assert ($hostCommand.Parameters.ContainsKey('ScriptPath') -and $hostCommand.Parameters.ContainsKey('AppDir')) 'Host builder must accept an isolated error fixture'
$hostFixture=Join-Path $PSScriptRoot 'output\tray-host-errors'
New-Item -ItemType Directory -Path $hostFixture -Force | Out-Null
$fixtureScript=Join-Path $hostFixture 'failing-tray.ps1'
Set-Content -LiteralPath $fixtureScript -Value 'if($env:SURROUNDFORGE_TEST_HOST_ERROR -eq "throw"){throw "fixture terminating failure"}; Write-Error "fixture nonterminating failure"'
$fixtureHost=Ensure-SurroundForgeHost -ScriptPath $fixtureScript -AppDir $hostFixture
$fixtureLog=Join-Path $hostFixture 'controller-launch.log'
foreach($kind in 'error','throw') {
  $env:SURROUNDFORGE_TEST_HOST_ERROR=$kind
  $beforeLength=if(Test-Path -LiteralPath $fixtureLog){([IO.File]::ReadAllText($fixtureLog)).Length}else{0}
  $child=Microsoft.PowerShell.Management\Start-Process -FilePath $fixtureHost -ArgumentList '-NoUi' -PassThru
  try {
    Assert ($child.WaitForExit(5000)) "Hosted $kind fixture must exit promptly"
    Assert ($child.ExitCode -ne 0) "Hosted $kind fixture must return failure"
    $newLog=([IO.File]::ReadAllText($fixtureLog)).Substring($beforeLength)
    $expected=if($kind -eq 'error'){'fixture nonterminating failure'}else{'fixture terminating failure'}
    Assert ($newLog.Contains($expected)) "Hosted $kind fixture must append its own failure to the error log"
  } finally {if(-not $child.HasExited){Microsoft.PowerShell.Management\Stop-Process -Id $child.Id -ErrorAction SilentlyContinue};$child.Dispose()}
}
Remove-Item Env:\SURROUNDFORGE_TEST_HOST_ERROR -ErrorAction SilentlyContinue
$successDir=Join-Path $PSScriptRoot 'output\tray-host-success'
New-Item -ItemType Directory -Path $successDir -Force | Out-Null
$successScript=Join-Path $successDir 'working-tray.ps1'
Set-Content -LiteralPath $successScript -Value 'param([switch]$Show,[switch]$NoUi) Start-Sleep -Milliseconds 1200; "fixture controller ready"'
$successHost=Ensure-SurroundForgeHost -ScriptPath $successScript -AppDir $successDir
$successChild=Microsoft.PowerShell.Management\Start-Process -FilePath $successHost -ArgumentList '-NoUi' -PassThru
try {
  Assert (Test-ControllerHostRunning $successHost) 'A scheduled launch must be able to confirm its exact controller host stayed running'
  Assert ($successChild.WaitForExit(5000)) 'Healthy hosted controller fixture must exit promptly'
  Assert ($successChild.ExitCode -eq 0) 'Healthy hosted controller fixture must return success'
  Assert (-not (Test-ControllerHostRunning $successHost)) 'Exited controller host must not count as a successful launch'
  Assert (-not (Test-Path -LiteralPath (Join-Path $successDir 'controller-launch.log'))) 'Healthy hosted controller must not produce a launch error'
} finally {if(-not $successChild.HasExited){Microsoft.PowerShell.Management\Stop-Process -Id $successChild.Id -ErrorAction SilentlyContinue};$successChild.Dispose()}
$oldRoot=$root;$oldLocalAppData=$env:LOCALAPPDATA
try {
  $root=Join-Path $hostFixture 'missing-installation'
  $env:LOCALAPPDATA=$hostFixture
  Ensure-BridgeTray 3>$null
  $missingLog=Join-Path $hostFixture 'SurroundForge\controller-launch.log'
  Assert ((Get-Content -LiteralPath $missingLog -Raw).Contains('Controller script is missing')) 'A missing controller script must leave a durable launch error'
} finally {$root=$oldRoot;$env:LOCALAPPDATA=$oldLocalAppData}
$engineFailureLog=Join-Path $hostFixture 'engine-failure.log'
Set-Content -LiteralPath $engineFailureLog -Value @('Started','Input ready','Output initialization failed: optical device unavailable')
Assert ((Get-BridgeStartupFailureDetail $engineFailureLog) -match 'optical device unavailable') 'Startup failure details must retain the native engine cause before the next retry overwrites its log'
$catalog = @(Get-SpeakerCatalog)
Assert ($catalog.Count -eq 8) 'All 8 surround speakers (FL, FC, FR, SL, LFE, SR, BL, BR) must be viewable in catalog'
Assert ((($catalog | Select-Object -ExpandProperty Code) -join ',') -eq 'FL,FC,FR,SL,LFE,SR,BL,BR') 'Speaker catalog must expose exact 8 speaker codes'
Assert ((($catalog | Select-Object -ExpandProperty Freq -Unique).Count) -eq 8) 'Every speaker must have a unique harmonic tone frequency description'
Assert (((Get-SpeakerLayoutSequence 'stereo') -join ',') -eq 'FL,FR') 'Stereo layout sequence must test FL,FR'
Assert (((Get-SpeakerLayoutSequence '5.1') -join ',') -eq 'FL,FC,FR,LFE,BL,BR') '5.1 layout sequence must test FL,FC,FR,LFE,BL,BR'
Assert (((Get-SpeakerLayoutSequence '7.1') -join ',') -eq 'FL,FC,FR,LFE,SL,SR,BL,BR') '7.1 layout sequence must test all 8 speakers'
$outputRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'output'))
foreach($fixturePath in @($hostFixture,$successDir)) {
  $resolved=[IO.Path]::GetFullPath($fixturePath)
  Assert ($resolved.StartsWith($outputRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Fixture cleanup must stay inside tests/output'
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output "PASS: tray status, Sonic Anvil taskbar icon host, 8-speaker interactive stage, Stereo/5.1/7.1 layout switcher, Stop & close, and mocked restart ($assertions assertions); no live audio changes."


