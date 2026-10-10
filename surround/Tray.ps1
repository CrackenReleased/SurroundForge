<# SurroundForge controls v0.1.16. Closing this UI never stops audio. #>
[CmdletBinding()]
param([switch]$Show,[switch]$NoUi)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Bridge.ps1') -FunctionsOnly

function Get-TrayStatus($Snapshot,$Previous,[datetime]$Now=[datetime]::UtcNow) {
  $result=[pscustomobject]@{Label='Stopped';Tone='Gray';Detail='Choose Start audio to enable surround.';Rate=$null}
  if($Snapshot.Error){$result.Label='Needs attention';$result.Tone='Red';$result.Detail='Status could not be read. Try Restart audio.';return $result}
  if(-not $Snapshot.Running) {
    if($Snapshot.Supervised){$result.Label='Recovering';$result.Tone='Amber';$result.Detail='Automatic recovery is retrying. Check the USB connection.'}
    return $result
  }
  $health=$Snapshot.Health
  if(-not $health -or $health.pid -ne $Snapshot.ProcessId){$result.Label='Starting';$result.Tone='Amber';$result.Detail='Waiting for the audio engine.';return $result}
  try {$age=($Now-([datetime]$health.updatedUtc).ToUniversalTime()).TotalSeconds} catch {$age=999}
  if($age -gt 5 -or $age -lt -5 -or $health.status -ne 'ready') {
    $result.Label='Needs attention';$result.Tone='Amber';$result.Detail='Audio health is delayed or failed. Restart audio if playback is affected.';return $result
  }
  $result.Label='Running';$result.Tone='Green';$result.Detail='Audio engine is responding. Checking delivery timing...'
  if($Previous -and $Previous.pid -eq $health.pid -and $null -ne $health.submittedFrames) {
    $seconds=(([datetime]$health.updatedUtc).ToUniversalTime()-([datetime]$Previous.updatedUtc).ToUniversalTime()).TotalSeconds
    if($seconds -ge 6 -and $seconds -le 30) {
      $frames=[double]$health.submittedFrames-[double]$Previous.submittedFrames
      $result.Rate=$frames/$seconds
      if([math]::Abs($frames-$seconds*48000) -gt (3072+$seconds*48000*0.02) -or $health.droppedPackets -gt $Previous.droppedPackets) {
        $result.Label='Needs attention';$result.Tone='Amber';$result.Detail='Audio delivery has been interrupted. Use Restart audio if it sounds wrong.'
      } else {$result.Detail='Audio delivery is on time. No new packet drops.'}
    }
  }
  return $result
}

function Start-TrayAction([ValidateSet('Start','Stop','Restart')][string]$Command) {
  if($script:TrayOperation){return}
  $process=New-Object Diagnostics.Process
  $process.StartInfo.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $process.StartInfo.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Bridge.ps1')+'" -Action '+$Command
  $process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
  $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
  try {
    [void]$process.Start()
    $script:TrayOperation=[pscustomobject]@{Process=$process;Output=$process.StandardOutput.ReadToEndAsync();Error=$process.StandardError.ReadToEndAsync();Command=$Command}
    $script:TrayUi.Note.Text=if($Command -eq 'Restart'){'Restarting audio. A brief silence is expected...'}else{"$Command audio in progress..."}
    foreach($item in $script:TrayUi.ActionControls){$item.Enabled=$false}
  } catch {$process.Dispose();$script:TrayUi.Note.Text='Could not start the audio control. '+$_.Exception.Message}
}

function Show-TrayWindow {
  $script:TrayUi.Form.ShowInTaskbar=$true
  $script:TrayUi.Form.WindowState='Normal'
  $script:TrayUi.Form.Show();$script:TrayUi.Form.Activate()
}
function Update-TrayUi {
  if($script:TrayShowEvent.WaitOne(0)){Show-TrayWindow}
  if($script:TrayOperation) {
    $operation=$script:TrayOperation
    if(-not $operation.Process.HasExited -or -not $operation.Output.IsCompleted -or -not $operation.Error.IsCompleted){return}
    $script:TrayUi.Note.Text=if($operation.Process.ExitCode -eq 0){$operation.Command+' audio complete.'}else{'Action failed: '+$operation.Error.Result.Trim()}
    $operation.Process.Dispose();$script:TrayOperation=$null;$script:TrayPrevious=$null
    foreach($item in $script:TrayUi.ActionControls){$item.Enabled=$true}
  }
  $snapshot=Get-BridgeSnapshot
  $status=Get-TrayStatus $snapshot $script:TrayPrevious
  $health=$snapshot.Health
  if(-not $script:TrayPrevious -or -not $health -or $script:TrayPrevious.pid -ne $health.pid -or
    (([datetime]$health.updatedUtc-([datetime]$script:TrayPrevious.updatedUtc)).TotalSeconds -ge 12)){$script:TrayPrevious=$health}
  $script:TrayUi.Status.Text=$status.Label
  $script:TrayUi.Status.ForeColor=$script:TrayColors[$status.Tone]
  $script:TrayUi.Detail.Text=$status.Detail
  $script:TrayUi.Icon.Icon=$script:TrayIcons[$status.Tone]
  $script:TrayUi.Icon.Text='SurroundForge - '+$status.Label
  $script:TrayUi.Form.Icon=$script:TrayIcons[$status.Tone]
  $script:TrayUi.Toggle.Text=if($snapshot.Running){'Stop audio'}else{'Start audio'}
  $script:TrayUi.MenuToggle.Text=$script:TrayUi.Toggle.Text
  $script:TrayUi.Auto.Text=if($snapshot.Supervised){'Automatic recovery is active'}else{'Automatic recovery is off'}
  $script:TrayRunning=$snapshot.Running
}

function Show-TrayUi {
  Add-Type -AssemblyName System.Windows.Forms,System.Drawing
  Add-Type -TypeDefinition @'
using System; using System.Drawing; using System.Runtime.InteropServices;
public static class SurroundForgeTrayIcon {
  [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
  public static Icon Create(Color color) {
    using(var bitmap=new Bitmap(32,32)) using(var g=Graphics.FromImage(bitmap))
    using(var brush=new SolidBrush(color)) using(var font=new Font("Segoe UI",16,FontStyle.Bold)) {
      g.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
      g.FillEllipse(brush,1,1,30,30);g.DrawString("S",font,Brushes.White,5,1);
      var handle=bitmap.GetHicon();try {return (Icon)Icon.FromHandle(handle).Clone();} finally {DestroyIcon(handle);}
    }
  }
}
'@
  [Windows.Forms.Application]::EnableVisualStyles()
  $script:TrayColors=@{Green=[Drawing.Color]::FromArgb(26,125,88);Amber=[Drawing.Color]::FromArgb(170,104,8);Red=[Drawing.Color]::FromArgb(185,44,54);Gray=[Drawing.Color]::FromArgb(100,112,125)}
  $script:TrayIcons=@{};foreach($tone in $script:TrayColors.Keys){$script:TrayIcons[$tone]=[SurroundForgeTrayIcon]::Create($script:TrayColors[$tone])}
  $form=New-Object Windows.Forms.Form
  $form.Text='SurroundForge - Audio status';$form.ClientSize=New-Object Drawing.Size(500,365)
  $form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
  $form.BackColor=[Drawing.Color]::White;$form.Font=New-Object Drawing.Font('Segoe UI',10)
  $form.AutoScaleMode='Dpi'
  function Add-TrayLabel($Text,$X,$Y,$Width,$Height,$Size=10) {
    $label=New-Object Windows.Forms.Label;$label.Text=$Text
    $label.Location=New-Object Drawing.Point($X,$Y);$label.Size=New-Object Drawing.Size($Width,$Height)
    $label.Font=New-Object Drawing.Font('Segoe UI',$Size);$form.Controls.Add($label);return $label
  }
  $null=Add-TrayLabel 'SURROUNDFORGE' 24 20 440 24 11
  $status=Add-TrayLabel 'Checking audio...' 24 53 450 45 25
  $detail=Add-TrayLabel 'Reading audio health...' 26 108 448 49
  $auto=Add-TrayLabel '' 26 165 448 24
  $null=Add-TrayLabel '5.1 optical audio  |  48 kHz sample rate' 26 194 448 24
  $restart=New-Object Windows.Forms.Button;$restart.Text='Restart audio';$restart.Location=New-Object Drawing.Point(24,236);$restart.Size=New-Object Drawing.Size(218,42)
  $restart.BackColor=[Drawing.Color]::FromArgb(25,84,150);$restart.ForeColor=[Drawing.Color]::White;$restart.FlatStyle='Flat'
  $toggle=New-Object Windows.Forms.Button;$toggle.Text='Start audio';$toggle.Location=New-Object Drawing.Point(254,236);$toggle.Size=New-Object Drawing.Size(218,42)
  $form.Controls.AddRange(@($restart,$toggle))
  $note=Add-TrayLabel 'Close this window to keep monitoring in the tray.' 26 292 448 42 9
  $version=Add-TrayLabel 'Controls v0.1.16  |  Audio engine v0.1.15' 26 340 448 20 8
  $version.ForeColor=[Drawing.Color]::DimGray
  $icon=New-Object Windows.Forms.NotifyIcon;$icon.Icon=$script:TrayIcons.Gray;$icon.Text='SurroundForge - Checking';$icon.Visible=$true
  $menu=New-Object Windows.Forms.ContextMenuStrip
  $open=$menu.Items.Add('Open audio status');$menuRestart=$menu.Items.Add('Restart audio');$menuToggle=$menu.Items.Add('Start audio')
  $null=$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
  $exit=$menu.Items.Add('Exit tray (audio continues)');$icon.ContextMenuStrip=$menu
  $script:TrayUi=@{Form=$form;Status=$status;Detail=$detail;Auto=$auto;Note=$note;Icon=$icon;Toggle=$toggle;MenuToggle=$menuToggle;ActionControls=@($restart,$toggle,$menuRestart,$menuToggle,$exit)}
  $restart.Add_Click({Start-TrayAction Restart});$menuRestart.Add_Click({Start-TrayAction Restart})
  $toggle.Add_Click({if($script:TrayRunning){Start-TrayAction Stop}else{Start-TrayAction Start}})
  $menuToggle.Add_Click({if($script:TrayRunning){Start-TrayAction Stop}else{Start-TrayAction Start}})
  $open.Add_Click({Show-TrayWindow});$icon.Add_DoubleClick({Show-TrayWindow})
  $form.Add_FormClosing({param($sender,$eventArgs) if(-not $script:TrayExiting){$eventArgs.Cancel=$true;$sender.Hide();$sender.ShowInTaskbar=$false}})
  $exit.Add_Click({$script:TrayExiting=$true;$form.Close();[Windows.Forms.Application]::ExitThread()})
  $timer=New-Object Windows.Forms.Timer;$timer.Interval=3000
  $timer.Add_Tick({try {Update-TrayUi} catch {$script:TrayUi.Status.Text='Needs attention';$script:TrayUi.Icon.Icon=$script:TrayIcons.Amber;$script:TrayUi.Note.Text='Status check failed. Restart audio if needed.'}})
  try {Update-TrayUi;$timer.Start();if($Show){Show-TrayWindow};[Windows.Forms.Application]::Run()}
  finally {$timer.Stop();$timer.Dispose();$icon.Visible=$false;$icon.Dispose();$menu.Dispose();$form.Dispose();foreach($value in $script:TrayIcons.Values){$value.Dispose()}}
}

if($NoUi){return}
$trayMutex=New-BridgeMutex 'tray'
$script:TrayShowEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,(Get-BridgeObjectName 'tray-show'))
if(-not (Enter-BridgeMutex $trayMutex 0)) {
  if($Show){[void]$script:TrayShowEvent.Set()}
  $script:TrayShowEvent.Dispose();$trayMutex.Dispose();exit
}
try {Show-TrayUi} finally {$script:TrayShowEvent.Dispose();$trayMutex.ReleaseMutex();$trayMutex.Dispose()}
