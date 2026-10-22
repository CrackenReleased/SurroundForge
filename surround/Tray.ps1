<# SurroundForge controls v0.1.16. Closing this UI never stops audio. #>
[CmdletBinding()]
param([switch]$Show,[switch]$NoUi)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Bridge.ps1') -FunctionsOnly

function Get-SpeakerCatalog {
  return @(
    [pscustomobject]@{Code='FL';Name='Front Left';Freq='196 Hz (G3)';Pin='Front Green (L)';X=16;Y=76;W=144;H=56}
    [pscustomobject]@{Code='FC';Name='Front Center';Freq='247 Hz (B3)';Pin='Center/Sub Orange (L)';X=184;Y=76;W=144;H=56}
    [pscustomobject]@{Code='FR';Name='Front Right';Freq='294 Hz (D4)';Pin='Front Green (R)';X=352;Y=76;W=144;H=56}
    [pscustomobject]@{Code='SL';Name='Side Left';Freq='392 Hz (G4)';Pin='Side Gray / Rear Black (L)';X=16;Y=144;W=144;H=56}
    [pscustomobject]@{Code='LFE';Name='Subwoofer (LFE)';Freq='55/98 Hz Sub';Pin='Center/Sub Orange (R)';X=184;Y=138;W=144;H=46}
    [pscustomobject]@{Code='SR';Name='Side Right';Freq='440 Hz (A4)';Pin='Side Gray / Rear Black (R)';X=352;Y=144;W=144;H=56}
    [pscustomobject]@{Code='BL';Name='Rear Left';Freq='330 Hz (E4)';Pin='Rear Black (L)';X=16;Y=212;W=144;H=56}
    [pscustomobject]@{Code='BR';Name='Rear Right';Freq='370 Hz (F#4)';Pin='Rear Black (R)';X=352;Y=212;W=144;H=56}
  )
}

function Get-SpeakerLayoutSequence([ValidateSet('stereo','5.1','7.1')][string]$Layout) {
  switch ($Layout) {
    'stereo' { return @('FL','FR') }
    '5.1'    { return @('FL','FC','FR','LFE','BL','BR') }
    '7.1'    { return @('FL','FC','FR','LFE','SL','SR','BL','BR') }
  }
}

function Get-TrayStatus($Snapshot,$Previous,[datetime]$Now=[datetime]::UtcNow) {
  $result=[pscustomobject]@{Label='Stopped';Tone='Gray';Detail='Choose Start audio to enable surround.';Rate=$null}
  if($Snapshot.Error){$result.Label='Off';$result.Tone='Red';$result.Detail='Audio service is offline or unreachable. Try Restart audio.';return $result}
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

function Start-TrayAction([ValidateSet('Start','Stop','Restart')][string]$Command,[switch]$ExitAfter) {
  if($script:TrayOperation){return}
  $process=New-Object Diagnostics.Process
  $process.StartInfo.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $process.StartInfo.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Bridge.ps1')+'" -Action '+$Command
  $process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
  $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
  try {
    [void]$process.Start()
    $script:TrayOperation=[pscustomobject]@{Process=$process;Output=$process.StandardOutput.ReadToEndAsync();Error=$process.StandardError.ReadToEndAsync();Command=$Command;ExitAfter=[bool]$ExitAfter}
    $script:TrayUi.Note.Text=if($Command -eq 'Restart'){'Restarting audio. A brief silence is expected...'}elseif($ExitAfter){'Stopping 5.1 audio and restoring defaults before closing...'}else{"$Command audio in progress..."}
    foreach($item in $script:TrayUi.ActionControls){$item.Enabled=$false}
  } catch {$process.Dispose();$script:TrayUi.Note.Text='Could not start the audio control. '+$_.Exception.Message}
}

function Stop-SpeakerToneProcess {
  if($script:SpeakerToneOp) {
    try {if(-not $script:SpeakerToneOp.Process.HasExited){$script:SpeakerToneOp.Process.Kill()}} catch {}
    try {$script:SpeakerToneOp.Process.Dispose()} catch {}
    $script:SpeakerToneOp=$null
  }
  $script:ActiveSpeakerCode=$null
  Update-SpeakerStageVisuals
}

function Start-SpeakerTone([string]$SpeakerCode,[switch]$FromSequence) {
  if(-not $FromSequence){$script:SpeakerTestQueue=$null;$script:TrayUi.BtnTestAll.Text='Test Layout'}
  if($script:SpeakerToneOp) {
    try {if(-not $script:SpeakerToneOp.Process.HasExited){$script:SpeakerToneOp.Process.Kill()}} catch {}
    try {$script:SpeakerToneOp.Process.Dispose()} catch {}
    $script:SpeakerToneOp=$null
  }
  if(-not $inputId -or -not (Test-Path -LiteralPath $control)) {
    $script:TrayUi.SpeakerReadout.Text='Virtual surround endpoint is not configured yet.'
    return
  }
  $meta=$script:SpeakerCatalogMap[$SpeakerCode]
  $layout=$script:SelectedLayout
  $process=New-Object Diagnostics.Process
  $process.StartInfo.FileName=$control
  $process.StartInfo.Arguments='--tone-speaker "'+$inputId+'" '+$SpeakerCode+' '+$layout
  $process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
  $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
  try {
    [void]$process.Start()
    $script:SpeakerToneOp=[pscustomobject]@{Process=$process;Code=$SpeakerCode;Layout=$layout}
    $script:ActiveSpeakerCode=$SpeakerCode
    $script:TrayUi.SpeakerReadout.Text="Playing $SpeakerCode ($($meta.Name)) - $($meta.Freq) | Jack: $($meta.Pin). Move/swap if misplaced."
    Update-SpeakerStageVisuals
  } catch {
    $process.Dispose()
    $script:TrayUi.SpeakerReadout.Text='Speaker tone failed: '+$_.Exception.Message
  }
}

function Set-SpeakerLayout([ValidateSet('stereo','5.1','7.1')][string]$Layout) {
  $script:SelectedLayout=$Layout
  $script:SpeakerTestQueue=$null
  if($script:TrayUi -and $script:TrayUi.BtnTestAll){$script:TrayUi.BtnTestAll.Text='Test Layout'}
  if($script:TrayUi) {
    $map=@{'stereo'=$script:TrayUi.BtnStereo;'5.1'=$script:TrayUi.Btn51;'7.1'=$script:TrayUi.Btn71}
    foreach($k in $map.Keys) {
      $btn=$map[$k]
      if($k -eq $Layout) {
        $btn.BackColor=[Drawing.Color]::FromArgb(25,84,150);$btn.ForeColor=[Drawing.Color]::White
      } else {
        $btn.BackColor=[Drawing.Color]::White;$btn.ForeColor=[Drawing.Color]::FromArgb(35,45,58)
      }
    }
    $script:TrayUi.LayoutHint.Text=switch($Layout) {
      'stereo' {'Stereo (2.0): FL & FR discrete; center/surround fold into L/R.'}
      '5.1'    {'5.1 Surround: FL, FC, FR, LFE, BL, BR discrete; SL/SR map to surround.'}
      '7.1'    {'7.1 Surround: All 8 speakers active in sequential test; SL/SR shimmer-coded.'}
    }
    $script:TrayUi.SpeakerReadout.Text="Layout set to $($Layout.ToUpper()). Click any speaker to play its unique tone, or click Test Layout."
    Update-SpeakerStageVisuals
  }
}

function Update-SpeakerStageVisuals {
  if(-not $script:TrayUi -or -not $script:TrayUi.SpeakerButtons){return}
  $activeSeq=Get-SpeakerLayoutSequence $script:SelectedLayout
  foreach($code in $script:TrayUi.SpeakerButtons.Keys) {
    $btn=$script:TrayUi.SpeakerButtons[$code]
    if($script:ActiveSpeakerCode -eq $code) {
      $btn.BackColor=[Drawing.Color]::FromArgb(0,168,138)
      $btn.ForeColor=[Drawing.Color]::White
    } elseif($activeSeq -contains $code) {
      $btn.BackColor=[Drawing.Color]::White
      $btn.ForeColor=[Drawing.Color]::FromArgb(20,30,45)
    } else {
      $btn.BackColor=[Drawing.Color]::FromArgb(234,238,244)
      $btn.ForeColor=[Drawing.Color]::FromArgb(95,108,125)
    }
  }
}

function Step-SpeakerToneState {
  if($script:SpeakerToneOp) {
    if(-not $script:SpeakerToneOp.Process.HasExited){return}
    $lastCode=$script:SpeakerToneOp.Code
    try {$script:SpeakerToneOp.Process.Dispose()} catch {}
    $script:SpeakerToneOp=$null
    $script:ActiveSpeakerCode=$null
    if($script:SpeakerTestQueue -and $script:SpeakerTestQueue.Count -gt 0) {
      $next=$script:SpeakerTestQueue[0]
      $script:SpeakerTestQueue=@($script:SpeakerTestQueue | Select-Object -Skip 1)
      Start-SpeakerTone $next -FromSequence
      return
    }
    $script:TrayUi.BtnTestAll.Text='Test Layout'
    $meta=$script:SpeakerCatalogMap[$lastCode]
    $script:TrayUi.SpeakerReadout.Text="Finished $lastCode ($($meta.Name)) at $($meta.Freq). Click any speaker to re-test or swap plugs."
    Update-SpeakerStageVisuals
  }
}

function Show-TrayWindow {
  $script:TrayUi.Form.ShowInTaskbar=$true
  $script:TrayUi.Form.WindowState='Normal'
  $handle=$script:TrayUi.Form.Handle
  $script:TrayUi.Form.Show()
  $script:TrayUi.Form.Visible=$true
  $tone=if($script:CurrentTone){$script:CurrentTone}else{'Green'}
  [SurroundForgeTrayIcon]::ShowForm($handle,$script:TrayIcons[$tone].Handle)
  $script:TrayUi.Form.BringToFront()
  $script:TrayUi.Form.Activate()
}

function Update-TrayUi {
  if($script:PendingInitialShow){$script:PendingInitialShow=$false;Show-TrayWindow}
  if($script:TrayShowEvent.WaitOne(0)){Show-TrayWindow}
  if($script:TrayOperation) {
    $operation=$script:TrayOperation
    if(-not $operation.Process.HasExited -or -not $operation.Output.IsCompleted -or -not $operation.Error.IsCompleted){return}
    $exitCode=$operation.Process.ExitCode
    $errorMsg=$operation.Error.Result.Trim()
    $operation.Process.Dispose();$script:TrayOperation=$null;$script:TrayPrevious=$null
    if($exitCode -eq 0 -and $operation.ExitAfter) {
      Stop-SpeakerToneProcess
      $script:TrayExiting=$true;$script:TrayUi.Form.Close();[Windows.Forms.Application]::ExitThread();return
    }
    $script:TrayUi.Note.Text=if($exitCode -eq 0){$operation.Command+' audio complete.'}else{'Action failed: '+$errorMsg}
    foreach($item in $script:TrayUi.ActionControls){$item.Enabled=$true}
  }
  $snapshot=Get-BridgeSnapshot
  $status=Get-TrayStatus $snapshot $script:TrayPrevious
  $health=$snapshot.Health
  if(-not $script:TrayPrevious -or -not $health -or $script:TrayPrevious.pid -ne $health.pid -or
    (([datetime]$health.updatedUtc-([datetime]$script:TrayPrevious.updatedUtc)).TotalSeconds -ge 12)){$script:TrayPrevious=$health}
  $script:CurrentTone=$status.Tone
  $script:TrayUi.Status.Text=$status.Label
  $script:TrayUi.Status.ForeColor=$script:TrayColors[$status.Tone]
  $script:TrayUi.Detail.Text=$status.Detail
  $script:TrayUi.Icon.Icon=$script:TrayIcons[$status.Tone]
  $script:TrayUi.Icon.Text='SurroundForge - '+$status.Label
  $script:TrayUi.Form.Icon=$script:TrayIcons[$status.Tone]
  [SurroundForgeTrayIcon]::ApplyWindowIcon($script:TrayUi.Form.Handle,$script:TrayIcons[$status.Tone].Handle)
  if($script:TrayUi.LogoBox){$script:TrayUi.LogoBox.Image=$script:TrayBitmaps[$status.Tone]}
  $script:TrayUi.Toggle.Text=if($snapshot.Running){'Stop audio'}else{'Start audio'}
  $script:TrayUi.MenuToggle.Text=$script:TrayUi.Toggle.Text
  $script:TrayUi.Auto.Text=if($snapshot.Supervised){'Automatic recovery is active'}else{'Automatic recovery is off'}
  $script:TrayRunning=$snapshot.Running
}

function Register-TrayNativeTypes {
  if('SurroundForgeTrayIcon' -as [type]){return}
  Add-Type -AssemblyName System.Windows.Forms,System.Drawing
  Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class SurroundForgeTrayIcon {
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
  [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
  [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint dwThreadId);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr hObj, int nIndex, StringBuilder pvInfo, int nLength, out int lpnLengthNeeded);

  public static string GetCurrentDesktopName() {
    IntPtr hDesk = GetThreadDesktop(GetCurrentThreadId());
    var sb = new StringBuilder(256);
    int len;
    if (GetUserObjectInformationW(hDesk, 2, sb, 512, out len)) return sb.ToString();
    return "Default";
  }

  public static void HideConsole() {
    try { SetCurrentProcessExplicitAppUserModelID("CrackenReleased.SurroundForge.Controller"); } catch {}
    IntPtr console = GetConsoleWindow();
    if (console != IntPtr.Zero) ShowWindow(console, 0);
  }

  public static void ApplyWindowIcon(IntPtr handle, IntPtr iconHandle) {
    if (handle != IntPtr.Zero && iconHandle != IntPtr.Zero) {
      SendMessage(handle, 0x0080, (IntPtr)0, iconHandle);
      SendMessage(handle, 0x0080, (IntPtr)1, iconHandle);
    }
  }

  public static void ShowForm(IntPtr handle, IntPtr iconHandle) {
    ApplyWindowIcon(handle, iconHandle);
    ShowWindow(handle, 1);
    ShowWindow(handle, 5);
    ShowWindow(handle, 9);
    SetForegroundWindow(handle);
  }

  public static Bitmap RenderSonicAnvilBitmap(Color waveColor, int size) {
    var bitmap = new Bitmap(size, size);
    using (var g = Graphics.FromImage(bitmap)) {
      g.SmoothingMode = SmoothingMode.AntiAlias;
      g.PixelOffsetMode = PixelOffsetMode.HighQuality;
      float s = size / 64f;

      using (var bgBrush = new SolidBrush(Color.FromArgb(250, 13, 17, 23)))
      using (var borderPen = new Pen(Color.FromArgb(140, waveColor), Math.Max(1.5f, 2f * s))) {
        g.FillEllipse(bgBrush, 2f * s, 2f * s, 60f * s, 60f * s);
        g.DrawEllipse(borderPen, 2f * s, 2f * s, 60f * s, 60f * s);
      }

      using (var wavePenOuter = new Pen(Color.FromArgb(235, waveColor), Math.Max(2.2f, 3.6f * s)))
      using (var wavePenInner = new Pen(Color.FromArgb(190, waveColor), Math.Max(1.8f, 3.0f * s))) {
        wavePenOuter.StartCap = LineCap.Round;
        wavePenOuter.EndCap = LineCap.Round;
        wavePenInner.StartCap = LineCap.Round;
        wavePenInner.EndCap = LineCap.Round;
        g.DrawArc(wavePenOuter, 7f * s, 7f * s, 50f * s, 50f * s, -145f, 225f);
        g.DrawArc(wavePenInner, 14f * s, 14f * s, 36f * s, 36f * s, -135f, 200f);
      }

      PointF[] anvilPoints = new PointF[] {
        new PointF(10f * s, 29f * s),
        new PointF(23f * s, 29f * s),
        new PointF(25f * s, 26f * s),
        new PointF(51f * s, 26f * s),
        new PointF(50f * s, 30f * s),
        new PointF(41f * s, 34f * s),
        new PointF(39f * s, 41f * s),
        new PointF(45f * s, 47f * s),
        new PointF(45f * s, 51f * s),
        new PointF(36f * s, 51f * s),
        new PointF(33f * s, 47f * s),
        new PointF(30f * s, 51f * s),
        new PointF(21f * s, 51f * s),
        new PointF(21f * s, 47f * s),
        new PointF(27f * s, 41f * s),
        new PointF(25f * s, 35f * s),
        new PointF(16f * s, 33f * s)
      };

      using (var anvilBrush = new LinearGradientBrush(
        new PointF(32f * s, 24f * s),
        new PointF(32f * s, 52f * s),
        Color.FromArgb(255, 255, 208, 84),
        Color.FromArgb(255, 230, 112, 20)))
      using (var highlightPen = new Pen(Color.FromArgb(230, 255, 242, 180), Math.Max(1.0f, 1.8f * s))) {
        g.FillPolygon(anvilBrush, anvilPoints);
        g.DrawLine(highlightPen, 25f * s, 26.5f * s, 50f * s, 26.5f * s);
      }
    }
    return bitmap;
  }

  public static void WriteSonicAnvilIco(string path) {
    int[] sizes = new int[] { 16, 32, 48, 64, 256 };
    byte[][] pngs = new byte[sizes.Length][];
    Color wave = Color.FromArgb(0, 228, 196);
    for (int i = 0; i < sizes.Length; i++) {
      using (var bmp = RenderSonicAnvilBitmap(wave, sizes[i]))
      using (var ms = new MemoryStream()) {
        bmp.Save(ms, ImageFormat.Png);
        pngs[i] = ms.ToArray();
      }
    }
    using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read))
    using (var bw = new BinaryWriter(fs)) {
      bw.Write((ushort)0);
      bw.Write((ushort)1);
      bw.Write((ushort)sizes.Length);
      int offset = 6 + (16 * sizes.Length);
      for (int i = 0; i < sizes.Length; i++) {
        int s = sizes[i];
        bw.Write((byte)(s >= 256 ? 0 : s));
        bw.Write((byte)(s >= 256 ? 0 : s));
        bw.Write((byte)0);
        bw.Write((byte)0);
        bw.Write((ushort)1);
        bw.Write((ushort)32);
        bw.Write((uint)pngs[i].Length);
        bw.Write((uint)offset);
        offset += pngs[i].Length;
      }
      for (int i = 0; i < sizes.Length; i++) {
        bw.Write(pngs[i]);
      }
    }
  }

  public static Icon Create(Color waveColor) {
    using (var bitmap = RenderSonicAnvilBitmap(waveColor, 64)) {
      var handle = bitmap.GetHicon();
      try { return (Icon)Icon.FromHandle(handle).Clone(); }
      finally { DestroyIcon(handle); }
    }
  }
}
'@
}

function Ensure-SurroundForgeHost {
  Register-TrayNativeTypes
  $appDir=Join-Path $env:LOCALAPPDATA 'SurroundForge'
  if(-not (Test-Path -LiteralPath $appDir)){New-Item -ItemType Directory -Path $appDir -Force | Out-Null}
  $icoPath=Join-Path $appDir 'surroundforge.ico'
  $exePath=Join-Path $appDir 'SurroundForge.exe'
  try {[SurroundForgeTrayIcon]::WriteSonicAnvilIco($icoPath)} catch {}
  $smaPath=[psobject].Assembly.Location
  $escapedScript=$PSCommandPath.Replace('\','\\').Replace('"','\"')
  $source=@"
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;

[assembly: System.Reflection.AssemblyTitle("SurroundForge Audio Controller")]
[assembly: System.Reflection.AssemblyProduct("SurroundForge")]
[assembly: System.Reflection.AssemblyDescription("SurroundForge - Audio Controller")]
[assembly: System.Reflection.AssemblyCompany("CrackenReleased")]

public static class SurroundForgeHost {
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);

  [STAThread]
  public static int Main(string[] args) {
    try { SetCurrentProcessExplicitAppUserModelID("CrackenReleased.SurroundForge.Controller"); } catch {}
    string scriptPath = "$escapedScript";
    bool show = false;
    bool noUi = false;
    foreach (string a in args) {
      if (string.Equals(a, "-Show", StringComparison.OrdinalIgnoreCase)) show = true;
      if (string.Equals(a, "-NoUi", StringComparison.OrdinalIgnoreCase)) noUi = true;
    }
    using (Runspace rs = RunspaceFactory.CreateRunspace()) {
      rs.ApartmentState = System.Threading.ApartmentState.STA;
      rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
      rs.Open();
      using (PowerShell ps = PowerShell.Create()) {
        ps.Runspace = rs;
        string cmd = "Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; & '" + scriptPath.Replace("'", "''") + "'" + (show ? " -Show" : "") + (noUi ? " -NoUi" : "");
        ps.AddScript(cmd);
        ps.Invoke();
      }
    }
    return 0;
  }
}
"@
  if(-not (Test-Path -LiteralPath $exePath)) {
    $provider=New-Object Microsoft.CSharp.CSharpCodeProvider
    $cp=New-Object System.CodeDom.Compiler.CompilerParameters
    $cp.GenerateExecutable=$true
    $cp.OutputAssembly=$exePath
    $cp.CompilerOptions='/target:winexe /win32icon:"'+$icoPath+'"'
    [void]$cp.ReferencedAssemblies.Add('System.dll')
    [void]$cp.ReferencedAssemblies.Add('System.Core.dll')
    [void]$cp.ReferencedAssemblies.Add($smaPath)
    $res=$provider.CompileAssemblyFromSource($cp,$source)
    $provider.Dispose()
    if($res.Errors.HasErrors) {
      throw ('Could not compile SurroundForge.exe host: '+($res.Errors | ForEach-Object {$_.ToString()} | Select-Object -First 1))
    }
  }
  return $exePath
}

function EnsureDefaultDesktop {
  Register-TrayNativeTypes
  $desk=[SurroundForgeTrayIcon]::GetCurrentDesktopName()
  $procName=[Diagnostics.Process]::GetCurrentProcess().ProcessName
  if($desk -ne 'Default' -or $procName -ne 'SurroundForge') {
    $exePath=Ensure-SurroundForgeHost
    $argStr=if($Show){' -Show'}else{''}
    $tr='"'+$exePath+'"'+$argStr
    $prev=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try {
      & schtasks.exe /Create /TN 'SurroundForge_Tray_Launch' /TR $tr /SC ONCE /ST 23:59 /IT /F *>$null
      & schtasks.exe /Run /TN 'SurroundForge_Tray_Launch' *>$null
    } finally {$ErrorActionPreference=$prev}
    return $true
  }
  return $false
}

function Show-TrayUi {
  Register-TrayNativeTypes
  [Windows.Forms.Application]::EnableVisualStyles()
  [SurroundForgeTrayIcon]::HideConsole()
  $script:TrayColors=@{Green=[Drawing.Color]::FromArgb(0,168,142);Amber=[Drawing.Color]::FromArgb(210,115,0);Red=[Drawing.Color]::FromArgb(205,40,50);Gray=[Drawing.Color]::FromArgb(90,105,125)}
  $script:TrayWaveColors=@{Green=[Drawing.Color]::FromArgb(0,228,196);Amber=[Drawing.Color]::FromArgb(250,160,10);Red=[Drawing.Color]::FromArgb(248,65,75);Gray=[Drawing.Color]::FromArgb(130,145,165)}
  $script:TrayIcons=@{};$script:TrayBitmaps=@{}
  foreach($tone in $script:TrayColors.Keys){
    $script:TrayIcons[$tone]=[SurroundForgeTrayIcon]::Create($script:TrayWaveColors[$tone])
    $script:TrayBitmaps[$tone]=[SurroundForgeTrayIcon]::RenderSonicAnvilBitmap($script:TrayWaveColors[$tone], 52)
  }
  $form=New-Object Windows.Forms.Form
  $form.Text='SurroundForge - Audio Controller';$form.ClientSize=New-Object Drawing.Size(560,618)
  $form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
  $form.BackColor=[Drawing.Color]::White;$form.Font=New-Object Drawing.Font('Segoe UI',10)
  $form.AutoScaleMode='Dpi'
  $logoBox=New-Object Windows.Forms.PictureBox
  $logoBox.Location=New-Object Drawing.Point(24,20);$logoBox.Size=New-Object Drawing.Size(52,52)
  $logoBox.SizeMode='StretchImage';$logoBox.Image=$script:TrayBitmaps.Green
  $form.Controls.Add($logoBox)
  function Add-TrayLabel($Parent,$Text,$X,$Y,$Width,$Height,$Size=10,$Style=[Drawing.FontStyle]::Regular) {
    $label=New-Object Windows.Forms.Label;$label.Text=$Text
    $label.Location=New-Object Drawing.Point($X,$Y);$label.Size=New-Object Drawing.Size($Width,$Height)
    $label.Font=New-Object Drawing.Font('Segoe UI',$Size,$Style);$Parent.Controls.Add($label);return $label
  }
  $null=Add-TrayLabel $form 'SURROUNDFORGE' 88 18 440 22 11 ([Drawing.FontStyle]::Bold)
  $status=Add-TrayLabel $form 'Checking audio...' 86 38 450 44 22 ([Drawing.FontStyle]::Bold)
  $detail=Add-TrayLabel $form 'Reading audio health...' 26 92 508 40 10
  $auto=Add-TrayLabel $form '' 26 134 508 22 9.5
  $null=Add-TrayLabel $form 'SurroundForge 5.1 optical audio  |  48 kHz sample rate' 26 158 508 22 9.5
  $restart=New-Object Windows.Forms.Button;$restart.Text='Restart audio';$restart.Location=New-Object Drawing.Point(24,188);$restart.Size=New-Object Drawing.Size(162,40)
  $restart.BackColor=[Drawing.Color]::FromArgb(25,84,150);$restart.ForeColor=[Drawing.Color]::White;$restart.FlatStyle='Flat'
  $toggle=New-Object Windows.Forms.Button;$toggle.Text='Start audio';$toggle.Location=New-Object Drawing.Point(199,188);$toggle.Size=New-Object Drawing.Size(162,40)
  $stopExit=New-Object Windows.Forms.Button;$stopExit.Text='Stop audio & close';$stopExit.UseMnemonic=$false;$stopExit.Location=New-Object Drawing.Point(374,188);$stopExit.Size=New-Object Drawing.Size(162,40)
  $stopExit.BackColor=[Drawing.Color]::FromArgb(168,38,48);$stopExit.ForeColor=[Drawing.Color]::White;$stopExit.FlatStyle='Flat'
  $form.Controls.AddRange(@($restart,$toggle,$stopExit))

  $stagePanel=New-Object Windows.Forms.Panel
  $stagePanel.Location=New-Object Drawing.Point(24,240);$stagePanel.Size=New-Object Drawing.Size(512,300)
  $stagePanel.BackColor=[Drawing.Color]::FromArgb(245,248,252);$stagePanel.BorderStyle='FixedSingle'
  $form.Controls.Add($stagePanel)

  $null=Add-TrayLabel $stagePanel 'SPEAKER LAYOUT:' 14 14 128 22 9 ([Drawing.FontStyle]::Bold)
  $btnStereo=New-Object Windows.Forms.Button;$btnStereo.Text='Stereo';$btnStereo.Location=New-Object Drawing.Point(144,9);$btnStereo.Size=New-Object Drawing.Size(72,30);$btnStereo.FlatStyle='Flat'
  $btn51=New-Object Windows.Forms.Button;$btn51.Text='5.1';$btn51.Location=New-Object Drawing.Point(222,9);$btn51.Size=New-Object Drawing.Size(72,30);$btn51.FlatStyle='Flat'
  $btn71=New-Object Windows.Forms.Button;$btn71.Text='7.1';$btn71.Location=New-Object Drawing.Point(300,9);$btn71.Size=New-Object Drawing.Size(72,30);$btn71.FlatStyle='Flat'
  $btnTestAll=New-Object Windows.Forms.Button;$btnTestAll.Text='Test Layout';$btnTestAll.Location=New-Object Drawing.Point(384,9);$btnTestAll.Size=New-Object Drawing.Size(112,30);$btnTestAll.FlatStyle='Flat'
  $btnTestAll.BackColor=[Drawing.Color]::FromArgb(20,148,115);$btnTestAll.ForeColor=[Drawing.Color]::White
  $stagePanel.Controls.AddRange(@($btnStereo,$btn51,$btn71,$btnTestAll))

  $speakerReadout=Add-TrayLabel $stagePanel 'Click any speaker to play its unique harmonic tone and verify physical placement or input jacks.' 14 44 484 26 8.5
  $speakerReadout.ForeColor=[Drawing.Color]::FromArgb(40,52,68)

  $listenerBadge=Add-TrayLabel $stagePanel '[ LISTENER POSITION ]' 184 188 144 20 8 ([Drawing.FontStyle]::Bold)
  $listenerBadge.TextAlign='MiddleCenter';$listenerBadge.ForeColor=[Drawing.Color]::FromArgb(90,105,122)

  $layoutHint=Add-TrayLabel $stagePanel '' 166 216 180 54 8
  $layoutHint.TextAlign='MiddleCenter';$layoutHint.ForeColor=[Drawing.Color]::FromArgb(80,95,112)

  $script:SpeakerCatalogMap=@{}
  $speakerButtons=@{}
  foreach($spk in (Get-SpeakerCatalog)) {
    $script:SpeakerCatalogMap[$spk.Code]=$spk
    $b=New-Object Windows.Forms.Button
    $b.UseMnemonic=$false
    $b.Text="$($spk.Code) - $($spk.Name)`r`n$($spk.Freq)"
    $b.Location=New-Object Drawing.Point($spk.X,$spk.Y)
    $b.Size=New-Object Drawing.Size($spk.W,$spk.H)
    $b.FlatStyle='Flat'
    $b.Font=New-Object Drawing.Font('Segoe UI',8.5,[Drawing.FontStyle]::Bold)
    $b.Tag=$spk.Code
    $b.Add_Click({param($sender,$e) Start-SpeakerTone ([string]$sender.Tag)})
    $stagePanel.Controls.Add($b)
    $speakerButtons[$spk.Code]=$b
  }

  $note=Add-TrayLabel $form 'Minimize or X to keep running in the tray, or click "Stop audio & close" to shut down.' 26 550 508 34 9
  $note.UseMnemonic=$false
  $version=Add-TrayLabel $form 'Controls v0.1.16  |  Audio engine v0.1.15  |  Sonic Anvil Harmonic Calibration' 26 590 508 20 8
  $version.ForeColor=[Drawing.Color]::DimGray
  $icon=New-Object Windows.Forms.NotifyIcon;$icon.Icon=$script:TrayIcons.Gray;$icon.Text='SurroundForge - Checking';$icon.Visible=$true
  $menu=New-Object Windows.Forms.ContextMenuStrip
  $open=$menu.Items.Add('Open audio controller');$menuRestart=$menu.Items.Add('Restart audio');$menuToggle=$menu.Items.Add('Start audio')
  $null=$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
  $menuStopExit=$menu.Items.Add('Stop audio & close')
  $exit=$menu.Items.Add('Hide controller (audio continues)');$icon.ContextMenuStrip=$menu
  $script:TrayUi=@{
    Form=$form;LogoBox=$logoBox;Status=$status;Detail=$detail;Auto=$auto;Note=$note;Icon=$icon;Toggle=$toggle;MenuToggle=$menuToggle;
    BtnStereo=$btnStereo;Btn51=$btn51;Btn71=$btn71;BtnTestAll=$btnTestAll;SpeakerReadout=$speakerReadout;LayoutHint=$layoutHint;
    SpeakerButtons=$speakerButtons;ActionControls=@($restart,$toggle,$stopExit,$menuRestart,$menuToggle,$menuStopExit,$exit)
  }
  Set-SpeakerLayout '5.1'
  $btnStereo.Add_Click({Set-SpeakerLayout 'stereo'})
  $btn51.Add_Click({Set-SpeakerLayout '5.1'})
  $btn71.Add_Click({Set-SpeakerLayout '7.1'})
  $btnTestAll.Add_Click({
    if($script:SpeakerTestQueue -or $script:SpeakerToneOp) {
      $script:SpeakerTestQueue=$null
      Stop-SpeakerToneProcess
      $script:TrayUi.BtnTestAll.Text='Test Layout'
      $script:TrayUi.SpeakerReadout.Text='Sequential layout test stopped.'
    } else {
      $seq=@(Get-SpeakerLayoutSequence $script:SelectedLayout)
      $first=$seq[0]
      $script:SpeakerTestQueue=@($seq | Select-Object -Skip 1)
      $script:TrayUi.BtnTestAll.Text='Stop Test'
      Start-SpeakerTone $first -FromSequence
    }
  })
  $restart.Add_Click({Start-TrayAction Restart});$menuRestart.Add_Click({Start-TrayAction Restart})
  $toggle.Add_Click({if($script:TrayRunning){Start-TrayAction Stop}else{Start-TrayAction Start}})
  $menuToggle.Add_Click({if($script:TrayRunning){Start-TrayAction Stop}else{Start-TrayAction Start}})
  $stopExit.Add_Click({Start-TrayAction Stop -ExitAfter});$menuStopExit.Add_Click({Start-TrayAction Stop -ExitAfter})
  $open.Add_Click({Show-TrayWindow});$icon.Add_Click({param($s,$e) if($e.Button -eq [Windows.Forms.MouseButtons]::Left){Show-TrayWindow}});$icon.Add_DoubleClick({Show-TrayWindow})
  $form.Add_FormClosing({param($sender,$eventArgs) if(-not $script:TrayExiting){$eventArgs.Cancel=$true;$sender.Hide();$sender.ShowInTaskbar=$false}})
  $exit.Add_Click({Stop-SpeakerToneProcess;$script:TrayExiting=$true;$form.Close();[Windows.Forms.Application]::ExitThread()})
  $timer=New-Object Windows.Forms.Timer;$timer.Interval=3000
  $timer.Add_Tick({try {Update-TrayUi} catch {$script:TrayUi.Status.Text='Needs attention';$script:TrayUi.Icon.Icon=$script:TrayIcons.Amber;$script:TrayUi.Note.Text='Status check failed. Restart audio if needed.'}})
  $showTimer=New-Object Windows.Forms.Timer;$showTimer.Interval=150
  $showTimer.Add_Tick({try {if($script:PendingInitialShow){$script:PendingInitialShow=$false;Show-TrayWindow};if($script:TrayShowEvent.WaitOne(0)){Show-TrayWindow};Step-SpeakerToneState} catch {}})
  $script:PendingInitialShow=[bool]$Show
  try {Update-TrayUi;$timer.Start();$showTimer.Start();if($Show){Show-TrayWindow};[Windows.Forms.Application]::Run()}
  finally {Stop-SpeakerToneProcess;$showTimer.Stop();$showTimer.Dispose();$timer.Stop();$timer.Dispose();$icon.Visible=$false;$icon.Dispose();$menu.Dispose();$form.Dispose();foreach($value in $script:TrayIcons.Values){$value.Dispose()};foreach($bmp in $script:TrayBitmaps.Values){$bmp.Dispose()}}
}

if($NoUi){return}
if(EnsureDefaultDesktop){exit}
$trayMutex=New-BridgeMutex 'tray-v3'
$script:TrayShowEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,(Get-BridgeObjectName 'tray-show-v3'))
$ownsMutex=Enter-BridgeMutex $trayMutex 0
if(-not $ownsMutex) {
  [void]$script:TrayShowEvent.Set()
  Start-Sleep -Milliseconds 450
  if(-not $script:TrayShowEvent.WaitOne(0)) {
    $script:TrayShowEvent.Dispose();$trayMutex.Dispose();exit
  }
}
try {Show-TrayUi} finally {$script:TrayShowEvent.Dispose();if($ownsMutex){try{$trayMutex.ReleaseMutex()}catch{}};$trayMutex.Dispose()}
