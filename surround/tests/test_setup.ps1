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
$brandedDevices=@(
  [pscustomobject]@{id='sf-virtual';name='SurroundForge 5.1 (VB-Audio Virtual Cable)';isSpdif=$false},
  [pscustomobject]@{id='sf-kernel';name='SurroundForge 5.1 (SurroundForge Audio)';isSpdif=$true},
  [pscustomobject]@{id='optical';name='SPDIF Out (USB Sound Device)';isSpdif=$true}
)
$brandedSelection=Get-SetupSelection $brandedDevices ''
Assert ($brandedSelection.Input.id -eq 'sf-virtual') 'Must recognize SurroundForge 5.1 branded virtual input'
Assert ($brandedSelection.Outputs.Count -eq 1 -and $brandedSelection.Outputs[0].id -eq 'optical') 'Never offer SurroundForge virtual endpoint as physical optical output'
$brandedDevices[0] | Add-Member NoteProperty active $false
$brandedDevices[2] | Add-Member NoteProperty active $true
Assert ((Get-SetupSelection $brandedDevices '').Input.id -eq 'sf-virtual') 'Setup must find its hidden configured input without exposing it in Windows'
Assert ((Get-SetupSelection @($script:Devices + $brandedDevices) '' 'sf-virtual').Input.id -eq 'sf-virtual') 'Setup must prefer its saved input over an older cable endpoint'
$sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
$sampleDir = Join-Path $sysDrive 'Sample'
$otherDir = Join-Path $sysDrive 'Other'
Assert (Test-SetupStartupOwner "-NoProfile -File `"$sampleDir\Bridge.ps1`" -Action Start" $sampleDir) 'Recognize this installation startup link'
Assert (-not (Test-SetupStartupOwner "-File `"$otherDir\Bridge.ps1`" -Action Start" $sampleDir)) 'Other installation startup link must not count as enabled'
Assert (-not (Test-SetupStartupOwner "-File `"$sampleDir\Bridge.ps1.extra`"" $sampleDir)) 'Startup ownership must compare the exact script path'

$allowed=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'output'))
$script:Fixture=[IO.Path]::GetFullPath((Join-Path $allowed 'setup-regression'))
Assert ($script:Fixture.StartsWith($allowed+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Fixture must remain inside tests/output'
New-Item -ItemType Directory -Path $script:Fixture -Force | Out-Null
$script:SetupRoot=$script:Fixture
$script:SetupDesktopPath=Join-Path $script:Fixture 'Desktop'
New-Item -ItemType Directory -Path $script:SetupDesktopPath -Force | Out-Null
$script:Calls=@();$script:FormatFails=$false;$script:StartFails=$false;$script:KeepState=$false
function Get-SetupDevices {return $script:Devices}
function Invoke-SetupControl([string[]]$Arguments) {
  if($Arguments[0] -eq '--visibility') {
    Assert ($Arguments[1] -eq 'virtual') 'Only the selected virtual input may change visibility'
    $script:Calls+=if($Arguments[2] -eq '1'){'show'}else{'hide'}
    return
  }
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
  Assert (($script:Calls -join ',') -eq 'Stop,show,format,Start,EnableStartup') 'Must stop before showing, formatting, starting and enabling startup'
  $text=[IO.File]::ReadAllText($config)
  foreach($line in 'in_id=virtual','out_id=optical','bitrate=448000','safe=1536','loopback=1','upmix=off') {Assert ($text.Contains($line)) "Missing configuration key: $line"}
  Assert (-not (Test-Path -LiteralPath ($config+'.new'))) 'Atomic configuration staging file must be cleaned'
  $bytes=[IO.File]::ReadAllBytes($config)
  Assert (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Native config must not gain a UTF-8 BOM'
  $desktopShortcut=Join-Path $script:SetupDesktopPath 'Start SoundForge.lnk'
  Assert (Test-Path -LiteralPath $desktopShortcut) 'Save-SetupConfiguration must create desktop start shortcut'
  $testShell=New-Object -ComObject WScript.Shell
  $testSc=$testShell.CreateShortcut($desktopShortcut)
  Assert ($testSc.Arguments -like "*-Action Start*") 'Desktop shortcut must invoke Action Start'
  Assert ($testSc.WorkingDirectory -eq $script:Fixture) 'Desktop shortcut must point to SetupRoot'
  Assert ($testSc.WindowStyle -eq 7) 'Desktop shortcut must run minimized (style 7)'

  $script:Calls=@()
  Expect-Failure {Save-SetupConfiguration 'virtual' 'virtual-stereo' $false} 'physical optical'
  Expect-Failure {Save-SetupConfiguration 'virtual' 'speakers' $false} 'physical optical'
  Assert ($script:Calls.Count -eq 0) 'Reject virtual physical output before any changes'
  Assert ([IO.File]::ReadAllText($config) -eq $text) 'Rejected selections must preserve config'

  $script:FormatFails=$true
  Expect-Failure {Save-SetupConfiguration 'virtual' 'optical' $false} 'Format rejected'
  Assert (($script:Calls -join ',') -eq 'show,format,hide') 'Failed setup format must hide the virtual endpoint again'
  Assert ([IO.File]::ReadAllText($config) -eq $text) 'Failed format change must preserve config'
  $script:FormatFails=$false;$script:Calls=@();$script:StartFails=$true
  Expect-Failure {Save-SetupConfiguration 'virtual' 'optical' $true} 'Start rejected'
  Assert (($script:Calls -join ',') -eq 'show,format,Start,hide') 'Failed Start must hide input and not enable startup'

  $script:StartFails=$false;$script:Calls=@()
  Save-SetupConfiguration 'virtual' 'optical' $false
  Assert (($script:Calls -join ',') -eq 'show,format,Start,DisableStartup') 'Unchecked startup preference must be respected'
  $script:KeepState=$true;$script:Calls=@();Set-Content -LiteralPath $state -Value '{}'
  Expect-Failure {Save-SetupConfiguration 'virtual' 'optical' $true} 'Previous audio settings'
  Assert (($script:Calls -join ',') -eq 'Stop') 'Unresolved rollback must block new format/config/start'
  Write-Output 'PASS: endpoint detection/optical preference, virtual-output rejection, atomic config, Stop-before-reconfigure, format/Start failure, startup choice and unresolved rollback guards'
} finally {
  # Delete only this test-owned, resolved fixture directory.
  Assert ($script:Fixture -eq [IO.Path]::GetFullPath((Join-Path $allowed 'setup-regression'))) 'Unexpected fixture cleanup path'
  Remove-Item -LiteralPath $script:Fixture -Recurse -Force
}
