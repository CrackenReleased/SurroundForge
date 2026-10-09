# Focused first-run setup regression; native audio and Bridge actions are mocked.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\Setup.ps1') -NoUi
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$script:Devices=@(
  [pscustomobject]@{id='virtual';name='CABLE In 16ch (VB-Audio Virtual Cable)';isSpdif=$false},
  [pscustomobject]@{id='virtual-stereo';name='CABLE Input (VB-Audio Virtual Cable)';isSpdif=$false},
  [pscustomobject]@{id='speakers';name='Laptop speakers';isSpdif=$false},
  [pscustomobject]@{id='optical';name='SPDIF Out (USB Sound Device)';isSpdif=$true}
)
$selection=Get-SetupSelection $script:Devices ''
Assert ($selection.Input.id -eq 'virtual') 'Must select exact multichannel cable endpoint'
Assert ($selection.Preferred.id -eq 'optical') 'Must prefer USB optical output'
Assert ($selection.Outputs.Count -eq 1) 'Only physical optical outputs may appear'
Assert ((Get-SetupSelection $script:Devices 'speakers').Preferred.id -eq 'optical') 'Never retain ordinary speakers as an optical output'
Assert (-not (Get-SetupSelection @($script:Devices | Where-Object {$_.id -ne 'virtual'}) '').Input) 'Stereo cable cannot replace multichannel input'
Assert (Test-SetupStartupOwner '-NoProfile -File "E:\Sample\Bridge.ps1" -Action Start' 'E:\Sample') 'Recognize this installation startup link'
Assert (-not (Test-SetupStartupOwner '-File "E:\Other\Bridge.ps1" -Action Start' 'E:\Sample')) 'Other installation startup link must not count as enabled'
Assert (-not (Test-SetupStartupOwner '-File "E:\Sample\Bridge.ps1.extra"' 'E:\Sample')) 'Startup ownership must compare the exact script path'

$allowed=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'output'))
$script:Fixture=[IO.Path]::GetFullPath((Join-Path $allowed 'setup-regression'))
Assert ($script:Fixture.StartsWith($allowed+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Fixture must remain inside tests/output'
New-Item -ItemType Directory -Path $script:Fixture -Force | Out-Null
$script:SetupRoot=$script:Fixture
$script:Calls=@();$script:FormatFails=$false;$script:StartFails=$false;$script:KeepState=$false
function Get-SetupDevices {return $script:Devices}
function Invoke-SetupControl([string[]]$Arguments) {
  $script:Calls+='format'
    Assert ($Arguments[0] -eq '--set-mix-51' -and $Arguments[1] -eq 'virtual') 'Only the selected multichannel input may change format'
  if($script:FormatFails){throw 'Format rejected'}
}
function Invoke-SetupBridge([string]$Action) {
  $script:Calls+=$Action
  if($Action -eq 'Stop' -and -not $script:KeepState){Remove-Item -LiteralPath (Join-Path $script:Fixture 'bridge-state.json') -ErrorAction SilentlyContinue}
  if($Action -eq 'Start' -and $script:StartFails){throw 'Start rejected'}
}
function Expect-Failure([scriptblock]$Operation,[string]$Text) {
  $failure=$null
  try {& $Operation} catch {$failure=$_}
  Assert ($failure -and $failure.Exception.Message -like "*$Text*") "Expected failure containing: $Text"
}
try {
  $drivers=Join-Path $script:Fixture 'Drivers'
  $packageSource=Join-Path $script:Fixture 'package-source'
  New-Item -ItemType Directory -Path (Join-Path $packageSource 'SoftwareDriver\InI') -Force | Out-Null
  New-Item -ItemType Directory -Path $drivers -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $packageSource 'setup.exe') -Value 'Mock vendor installer; never execute'
  Set-Content -LiteralPath (Join-Path $packageSource 'SoftwareDriver\InI\settings.ini') -Value 'Original nested vendor data'
  $zip=Join-Path $drivers 'C-Media.zip'
  Compress-Archive -Path (Join-Path $packageSource '*') -DestinationPath $zip
  $installer=Get-SetupCmediaInstaller
  Assert (Test-Path -LiteralPath $installer) 'Compressed vendor package must expose setup.exe'
  Assert (Test-Path -LiteralPath (Join-Path $drivers 'C-Media\SoftwareDriver\InI\settings.ini')) 'Preserve full vendor package tree'
  Remove-Item -LiteralPath $zip
  Assert ((Get-SetupCmediaInstaller) -eq $installer) 'Existing complete package must not be extracted again'
  Remove-Item -LiteralPath $installer
  Set-Content -LiteralPath $zip -Value 'Invalid zip used to reproduce interrupted extraction'
  Expect-Failure {Get-SetupCmediaInstaller} ''
  Assert (-not (Test-Path -LiteralPath (Join-Path $drivers 'C-Media'))) 'Failed extraction must clean only its checked package folder'
  $config=Join-Path $script:Fixture 'bridge.conf'
  $state=Join-Path $script:Fixture 'bridge-state.json'
  Set-Content -LiteralPath $state -Value '{}'
  Set-Content -LiteralPath $config -Value 'old configuration'
  Save-SetupConfiguration 'virtual' 'optical' $true
  Assert (($script:Calls -join ',') -eq 'Stop,format,Start,EnableStartup') 'Must stop before format/save/start and enable startup last'
  $text=[IO.File]::ReadAllText($config)
  foreach($line in 'in_id=virtual','out_id=optical','bitrate=448000','safe=1536','loopback=1','upmix=off') {Assert ($text.Contains($line)) "Missing configuration key: $line"}
  Assert (-not (Test-Path -LiteralPath ($config+'.new'))) 'Atomic configuration staging file must be cleaned'
  $bytes=[IO.File]::ReadAllBytes($config)
  Assert (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Native config must not gain a UTF-8 BOM'

  $script:Calls=@()
  Expect-Failure {Save-SetupConfiguration 'virtual' 'virtual-stereo' $false} 'physical optical'
  Expect-Failure {Save-SetupConfiguration 'virtual' 'speakers' $false} 'physical optical'
  Assert ($script:Calls.Count -eq 0) 'Reject virtual physical output before any changes'
  Assert ([IO.File]::ReadAllText($config) -eq $text) 'Rejected selections must preserve config'

  $script:FormatFails=$true
  Expect-Failure {Save-SetupConfiguration 'virtual' 'optical' $false} 'Format rejected'
  Assert ([IO.File]::ReadAllText($config) -eq $text) 'Failed format change must preserve config'
  $script:FormatFails=$false;$script:Calls=@();$script:StartFails=$true
  Expect-Failure {Save-SetupConfiguration 'virtual' 'optical' $true} 'Start rejected'
  Assert (($script:Calls -join ',') -eq 'format,Start') 'Failed Start must not enable startup'

  $script:StartFails=$false;$script:Calls=@()
  Save-SetupConfiguration 'virtual' 'optical' $false
  Assert (($script:Calls -join ',') -eq 'format,Start,DisableStartup') 'Unchecked startup preference must be respected'
  $script:KeepState=$true;$script:Calls=@();Set-Content -LiteralPath $state -Value '{}'
  Expect-Failure {Save-SetupConfiguration 'virtual' 'optical' $true} 'Previous audio settings'
  Assert (($script:Calls -join ',') -eq 'Stop') 'Unresolved rollback must block new format/config/start'
  Write-Output 'PASS: endpoint detection/optical preference, virtual-output rejection, atomic config, Stop-before-reconfigure, format/Start failure, startup choice and unresolved rollback guards'
} finally {
  # Delete only this test-owned, resolved fixture directory.
  Assert ($script:Fixture -eq [IO.Path]::GetFullPath((Join-Path $allowed 'setup-regression'))) 'Unexpected fixture cleanup path'
  Remove-Item -LiteralPath $script:Fixture -Recurse -Force
}
