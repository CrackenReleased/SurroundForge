<# First-run setup for SurroundForge. Windows PowerShell 5.1. #>
[CmdletBinding()]
param([switch]$NoUi)
$ErrorActionPreference='Stop'
$script:SetupRoot=$PSScriptRoot

function Get-SetupRuntime {
  $installed=Join-Path $script:SetupRoot 'Runtime\bridge_control.exe'
  if(Test-Path -LiteralPath $installed){return $installed}
  $development=Join-Path $script:SetupRoot 'source\engine\build\Release\bridge_control.exe'
  if(Test-Path -LiteralPath $development){return $development}
  throw 'The surround audio component is missing. Please reinstall SurroundForge.'
}
function Invoke-SetupControl([string[]]$Arguments) {
  $controller=Get-SetupRuntime
  $result=& $controller @Arguments
  if($LASTEXITCODE -ne 0){throw "Audio configuration failed ($LASTEXITCODE). Check that the selected devices are connected."}
  return $result
}
function Test-SetupVirtualOutput($Device) {
  return ($Device.name -match '(?i)VB-Audio|\bCABLE\b')
}
function Get-SetupDevices {
  $json=(Invoke-SetupControl @('--devices-json')) -join [Environment]::NewLine
  $devices=@($json | ConvertFrom-Json)
  foreach($device in $devices) {
    if(-not $device.id -or -not $device.name){throw 'The audio device list could not be read. Please refresh.'}
  }
  return $devices
}
function Get-SetupHardware {
  $attached=$false;$installed=$false;$errorText=$null
  try {
    # Query only the supported adapter family instead of enumerating the whole machine.
    $hardware=@(Get-PnpDevice -InstanceId 'USB\VID_0D8C&PID_0102*' -PresentOnly -ErrorAction SilentlyContinue)
    $attached=$hardware.Count -gt 0
    foreach($device in $hardware) {
      $provider=Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_DriverProvider' -ErrorAction SilentlyContinue
      if($provider.Data -match '(?i)C[- ]?MEDIA'){$installed=$true}
    }
  } catch {$errorText='Windows could not check the connected USB adapter. Refresh after connecting it.'}
  return [pscustomobject]@{Attached=$attached;Installed=$installed;ErrorText=$errorText}
}
function Get-SetupSelection($Devices,[string]$SavedOutput) {
  $inputDevice=@($Devices | Where-Object {$_.name -eq 'CABLE In 16ch (VB-Audio Virtual Cable)'}) | Select-Object -First 1
  $outputs=@($Devices | Where-Object {$_.isSpdif -and -not (Test-SetupVirtualOutput $_)})
  $preferred=@($outputs | Where-Object {$_.id -eq $SavedOutput}) | Select-Object -First 1
  if(-not $preferred){$preferred=@($outputs | Where-Object {$_.isSpdif -and $_.name -match '(?i)USB'}) | Select-Object -First 1}
  if(-not $preferred){$preferred=@($outputs | Where-Object {$_.isSpdif}) | Select-Object -First 1}
  if(-not $preferred){$preferred=$outputs | Select-Object -First 1}
  return [pscustomobject]@{Input=$inputDevice;Outputs=$outputs;Preferred=$preferred}
}
function Get-SetupSavedOutput {
  $path=Join-Path $script:SetupRoot 'bridge.conf'
  if(Test-Path -LiteralPath $path) {
    foreach($line in Get-Content -LiteralPath $path){if($line -match '^out_id=(.+)$'){return $Matches[1].Trim()}}
  }
  return ''
}
function Test-SetupStartupOwner([string]$Arguments,[string]$Root) {
  if($Arguments -match '(?i)(?:^|\s)-File\s+"([^"]+)"'){$target=$Matches[1]}
  elseif($Arguments -match '(?i)(?:^|\s)-File\s+(\S+)'){$target=$Matches[1]}
  else{return $false}
  try {return [IO.Path]::GetFullPath($target) -eq [IO.Path]::GetFullPath((Join-Path $Root 'Bridge.ps1'))}
  catch {return $false}
}
function Get-SetupStartupChoice {
  $path=Join-Path ([Environment]::GetFolderPath('Startup')) 'SurroundForge.lnk'
  if(-not (Test-Path -LiteralPath $path)){return $true}
  try {
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$shell.CreateShortcut($path)
    return Test-SetupStartupOwner $shortcut.Arguments $script:SetupRoot
  } catch {return $false}
}
function Invoke-SetupBridge([ValidateSet('Start','Stop','EnableStartup','DisableStartup')][string]$Action) {
  $info=New-Object Diagnostics.ProcessStartInfo
  $info.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $bridge=Join-Path $script:SetupRoot 'Bridge.ps1'
  $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$bridge+'" -Action '+$Action
  $info.WorkingDirectory=$script:SetupRoot
  $info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $process=New-Object Diagnostics.Process
  $process.StartInfo=$info
  try {
    if(-not $process.Start()){throw 'The surround controller could not be started.'}
    $outputTask=$process.StandardOutput.ReadToEndAsync()
    $errorTask=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(30000)){throw 'Audio setup took too long. Close this window, then reopen setup.'}
    $output=$outputTask.Result;$failure=$errorTask.Result
    if($process.ExitCode -ne 0){throw (($failure+[Environment]::NewLine+$output).Trim())}
    return $output.Trim()
  } finally {$process.Dispose()}
}
function Save-SetupConfiguration([string]$InputId,[string]$OutputId,[bool]$Startup) {
  # Re-read endpoint identity immediately before changing anything.
  $devices=Get-SetupDevices
  $inputDevice=$devices | Where-Object {$_.id -eq $InputId -and $_.name -eq 'CABLE In 16ch (VB-Audio Virtual Cable)'} | Select-Object -First 1
  $outputDevice=$devices | Where-Object {$_.id -eq $OutputId} | Select-Object -First 1
  if(-not $inputDevice){throw 'Install VB-CABLE, restart if requested, then refresh this window.'}
  if(-not $outputDevice -or -not $outputDevice.isSpdif -or $InputId -eq $OutputId -or (Test-SetupVirtualOutput $outputDevice)) {
    throw 'Select your physical optical output, rather than a virtual cable.'
  }
  $statePath=Join-Path $script:SetupRoot 'bridge-state.json'
  if(Test-Path -LiteralPath $statePath) {
    Invoke-SetupBridge Stop | Out-Null
    if(Test-Path -LiteralPath $statePath){throw 'Previous audio settings could not be restored. Reconnect the previous output, then try again.'}
  }
  Invoke-SetupControl @('--set-mix-51',$InputId) | Out-Null
  $path=Join-Path $script:SetupRoot 'bridge.conf'
  $pending=$path+'.new'
  $text=@("in_id=$InputId","out_id=$OutputId",'bitrate=448000','safe=1536','loopback=1','upmix=off') -join [Environment]::NewLine
  try {
    [IO.File]::WriteAllText($pending,$text+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
    if(Test-Path -LiteralPath $path){[IO.File]::Replace($pending,$path,[NullString]::Value)}else{[IO.File]::Move($pending,$path)}
  } finally {if(Test-Path -LiteralPath $pending){Remove-Item -LiteralPath $pending}}
  Invoke-SetupBridge Start | Out-Null
  if($Startup){Invoke-SetupBridge EnableStartup | Out-Null}else{Invoke-SetupBridge DisableStartup | Out-Null}
}

function Get-SetupCmediaInstaller {
  $allowed=[IO.Path]::GetFullPath((Join-Path $script:SetupRoot 'Drivers\C-Media'))
  $path=Join-Path $allowed 'setup.exe'
  if(Test-Path -LiteralPath $path){return $path}
  $archive=Join-Path $script:SetupRoot 'Drivers\C-Media.zip'
  if(-not (Test-Path -LiteralPath $archive)){throw 'The USB optical driver package is missing. Please reinstall SurroundForge.'}
  # A prior interrupted extraction may have left only part of the vendor package.
  # Cleanup is permitted only at this exact package-owned directory.
  $target=[IO.Path]::GetFullPath($allowed)
  if($target -ne [IO.Path]::GetFullPath((Join-Path $script:SetupRoot 'Drivers\C-Media'))){throw 'Unexpected driver package location.'}
  try {
    if(Test-Path -LiteralPath $target){Remove-Item -LiteralPath $target -Recurse -Force}
    Expand-Archive -LiteralPath $archive -DestinationPath $target -Force
    if(-not (Test-Path -LiteralPath $path)){throw 'The USB optical driver package could not be opened.'}
    return $path
  } catch {
    if($target -eq [IO.Path]::GetFullPath((Join-Path $script:SetupRoot 'Drivers\C-Media')) -and (Test-Path -LiteralPath $target)) {
      Remove-Item -LiteralPath $target -Recurse -Force
    }
    throw
  }
}

function Show-SetupUi {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [Windows.Forms.Application]::EnableVisualStyles()
  $form=New-Object Windows.Forms.Form
  $form.Text='SurroundForge - Setup';$form.ClientSize=New-Object Drawing.Size(736,590)
  $form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
  $form.Font=New-Object Drawing.Font('Segoe UI',10);$form.BackColor=[Drawing.Color]::White
  function Add-Label([string]$Text,[int]$Y,[int]$Height) {
    $label=New-Object Windows.Forms.Label;$label.Text=$Text;$label.Location=New-Object Drawing.Point(24,$Y)
    $label.Size=New-Object Drawing.Size(688,$Height);$form.Controls.Add($label);return $label
  }
  $title=Add-Label 'Set up your surround sound' 22 38
  $title.Font=New-Object Drawing.Font('Segoe UI',19,[Drawing.FontStyle]::Bold)
  $title.ForeColor=[Drawing.Color]::FromArgb(22,52,86)
  $null=Add-Label 'Enable real-time 5.1 through your USB optical adapter. Select its output below.' 68 40
  $drivers=Add-Label '1. Audio devices' 120 26;$drivers.Font=New-Object Drawing.Font('Segoe UI',11,[Drawing.FontStyle]::Bold)
  $driverStatus=Add-Label 'Checking your audio devices...' 153 52
  $vbButton=New-Object Windows.Forms.Button;$vbButton.Text='Install VB-CABLE';$vbButton.Location=New-Object Drawing.Point(24,211);$vbButton.Size=New-Object Drawing.Size(180,34)
  $cmButton=New-Object Windows.Forms.Button;$cmButton.Text='Install USB optical driver';$cmButton.Location=New-Object Drawing.Point(216,211);$cmButton.Size=New-Object Drawing.Size(220,34)
  $refresh=New-Object Windows.Forms.Button;$refresh.Text='Refresh devices';$refresh.Location=New-Object Drawing.Point(550,211);$refresh.Size=New-Object Drawing.Size(162,34)
  $form.Controls.AddRange(@($vbButton,$cmButton,$refresh))
  $license=New-Object Windows.Forms.LinkLabel;$license.Text='VB-CABLE is VB-Audio donationware; donations welcome.'
  $license.Location=New-Object Drawing.Point(24,258);$license.Size=New-Object Drawing.Size(688,24)
  $license.Add_LinkClicked({try{Start-Process 'https://vb-audio.com/Cable/'}catch{$script:SetupUi.Status.Text='Could not open the VB-Audio website.'}})
  $form.Controls.Add($license)
  $outputsLabel=Add-Label '2. Optical output' 302 28;$outputsLabel.Font=New-Object Drawing.Font('Segoe UI',11,[Drawing.FontStyle]::Bold)
  $outputs=New-Object Windows.Forms.ComboBox;$outputs.Location=New-Object Drawing.Point(24,340)
  $outputs.Size=New-Object Drawing.Size(688,30);$outputs.DropDownStyle='DropDownList';$outputs.DisplayMember='label'
  $form.Controls.Add($outputs)
  $help=Add-Label '' 379 63;$help.ForeColor=[Drawing.Color]::FromArgb(70,70,70)
  $startup=New-Object Windows.Forms.CheckBox;$startup.Text='Start surround sound when I sign in';$startup.Location=New-Object Drawing.Point(24,450);$startup.Size=New-Object Drawing.Size(430,28)
  $startup.Checked=Get-SetupStartupChoice
  $form.Controls.Add($startup)
  $status=Add-Label '' 494 61;$status.ForeColor=[Drawing.Color]::FromArgb(22,52,86)
  $configure=New-Object Windows.Forms.Button;$configure.Text='Save and start surround';$configure.Location=New-Object Drawing.Point(475,450)
  $configure.Size=New-Object Drawing.Size(237,36);$configure.BackColor=[Drawing.Color]::FromArgb(22,70,120);$configure.ForeColor=[Drawing.Color]::White
  $form.Controls.Add($configure)
  $script:SetupUi=[pscustomobject]@{Form=$form;DriverStatus=$driverStatus;Vb=$vbButton;Cm=$cmButton;Refresh=$refresh;Outputs=$outputs;Help=$help;Startup=$startup;Status=$status;Configure=$configure;Input=$null;Installer=$null;InstallerKind='';Timer=$null}
  function Refresh-SetupUi {
    $ui=$script:SetupUi
    try {
      $selection=Get-SetupSelection (Get-SetupDevices) (Get-SetupSavedOutput)
      $hardware=Get-SetupHardware
      $ui.Input=$selection.Input;$ui.Outputs.Items.Clear()
      foreach($device in $selection.Outputs) {
        $label=$device.name;if($device.isSpdif){$label+=' (optical)'}
        $entry=[pscustomobject]@{id=$device.id;name=$device.name;label=$label}
        $index=$ui.Outputs.Items.Add($entry)
        if($selection.Preferred -and $device.id -eq $selection.Preferred.id){$ui.Outputs.SelectedIndex=$index}
      }
      $hasOptical=@($selection.Outputs).Count -gt 0
      $virtualText=if($selection.Input){'Virtual surround device: ready.'}else{'Virtual surround device: install VB-CABLE, then restart if requested.'}
      $usbText=if($hardware.Installed){'USB optical driver: installed.'}elseif($hardware.Attached){'USB optical adapter: connected; driver available below.'}elseif($hasOptical){'Optical output detected. A built-in optical output does not need the C-Media driver.'}else{'USB optical adapter: connect your adapter, then refresh.'}
      $ui.DriverStatus.Text=$virtualText+[Environment]::NewLine+$usbText
      $busy=[bool]$ui.Installer
      $ui.Vb.Enabled=(-not $busy -and -not $selection.Input)
      $ui.Cm.Enabled=(-not $busy -and $hardware.Attached -and -not $hardware.Installed)
      $ui.Configure.Enabled=(-not $busy -and [bool]$selection.Input -and $ui.Outputs.SelectedIndex -ge 0)
      $hasOpticalUsb=@($selection.Outputs | Where-Object {$_.isSpdif -and $_.name -match '(?i)USB'}).Count -gt 0
      $ui.Help.Text=if($hardware.Attached -and -not $hasOpticalUsb){'In Xear Audio Center: right-click Speakers, open Speaker Settings, then choose SPDIF Out. Select the optical input on your receiver. Refresh this window afterward.'}else{'Select the optical input on your receiver. Your normal Windows volume control will adjust listening volume.'}
      if($hardware.ErrorText){$ui.Status.Text=$hardware.ErrorText}
    } catch {$ui.Status.Text=$_.Exception.Message;$ui.Configure.Enabled=$false;$ui.Vb.Enabled=$false;$ui.Cm.Enabled=$false}
  }
  function Start-SetupInstaller([ValidateSet('VB','CMedia')][string]$Kind) {
    $ui=$script:SetupUi
    try {
      if($ui.Installer){throw 'A driver installer is already running. Complete it before continuing.'}
      $devices=Get-SetupDevices
      if($Kind -eq 'VB') {
        if(@($devices | Where-Object {$_.name -match '(?i)VB-Audio.*Cable'}).Count){throw 'VB-CABLE is already installed. Restart if requested, then refresh.'}
        $path=Join-Path $script:SetupRoot 'Drivers\VB-CABLE\VBCABLE_Setup_x64.exe'
      } else {
        $hardware=Get-SetupHardware
        if(-not $hardware.Attached){throw 'Connect the supported USB optical adapter before installing its driver.'}
        if($hardware.Installed){throw 'The USB optical driver is already installed. Use Xear Audio Center to select SPDIF Out.'}
        $path=Get-SetupCmediaInstaller
      }
      if(-not (Test-Path -LiteralPath $path)){throw 'This driver installer is missing. Please reinstall SurroundForge.'}
      $existing=Get-Process -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $path} | Select-Object -First 1
      if($existing){throw 'This driver installer is already open. Complete it before continuing.'}
      $ui.Installer=Start-Process -FilePath $path -WorkingDirectory (Split-Path $path) -Verb RunAs -WindowStyle Normal -PassThru
      $ui.InstallerKind=$Kind;$ui.Vb.Enabled=$false;$ui.Cm.Enabled=$false;$ui.Configure.Enabled=$false
      $ui.Status.Text='Complete the vendor installer. It may require a restart; reopen this setup afterward.'
      $ui.Timer.Start()
    } catch {$ui.Status.Text=$_.Exception.Message}
  }
  $timer=New-Object Windows.Forms.Timer;$timer.Interval=700;$script:SetupUi.Timer=$timer
  $timer.Add_Tick({
    $ui=$script:SetupUi
    try {
      $ui.Installer.Refresh()
      if($ui.Installer.HasExited){$ui.Timer.Stop();$ui.Installer.Dispose();$ui.Installer=$null;Refresh-SetupUi;$ui.Status.Text='Installer finished. If it requested a restart, restart Windows and reopen setup. Otherwise refresh devices.'}
    } catch {$ui.Timer.Stop();$ui.Status.Text='Complete the vendor installer, then restart if requested and reopen setup.'}
  })
  $vbButton.Add_Click({Start-SetupInstaller VB});$cmButton.Add_Click({Start-SetupInstaller CMedia})
  $refresh.Add_Click({Refresh-SetupUi})
  $outputs.Add_SelectedIndexChanged({$ui=$script:SetupUi;$ui.Configure.Enabled=(-not $ui.Installer -and [bool]$ui.Input -and $ui.Outputs.SelectedIndex -ge 0)})
  $configure.Add_Click({
    $ui=$script:SetupUi;$ui.Configure.Enabled=$false;$ui.Status.Text='Configuring your surround sound...';$ui.Form.Refresh()
    try {
      if(-not $ui.Input -or -not $ui.Outputs.SelectedItem){throw 'Refresh devices and choose your optical output first.'}
      Save-SetupConfiguration $ui.Input.id $ui.Outputs.SelectedItem.id $ui.Startup.Checked
      $ui.Status.Text='Surround sound is running. Set games to 5.1; ordinary stereo audio remains stereo.'
    } catch {[Windows.Forms.MessageBox]::Show($ui.Form,$_.Exception.Message,'Audio setup',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning) | Out-Null;$ui.Status.Text='Setup needs attention. Check the message, then try again.'}
    finally {$ui.Configure.Enabled=(-not $ui.Installer -and [bool]$ui.Input -and $ui.Outputs.SelectedIndex -ge 0)}
  })
  $form.Add_FormClosed({$script:SetupUi.Timer.Stop();$script:SetupUi.Timer.Dispose()})
  $vbButton.Enabled=$false;$cmButton.Enabled=$false;$configure.Enabled=$false
  $form.Add_Shown({$script:SetupUi.Form.Refresh();Refresh-SetupUi})
  try {$form.ShowDialog() | Out-Null} finally {$form.Dispose()}
}

if(-not $NoUi){Show-SetupUi}
