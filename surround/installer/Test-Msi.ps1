[CmdletBinding()]
param([switch]$InstallRoundTrip,[string]$UpgradeFromMsi='', [string]$SigningConfiguration='', [switch]$DevelopmentUnsigned)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Signing.ps1')
if($DevelopmentUnsigned -and $SigningConfiguration){throw 'Choose signed release or unsigned development, not both.'}
$policy=if(-not $DevelopmentUnsigned){Read-SigningConfiguration $SigningConfiguration}else{$null}
$root=Split-Path $PSScriptRoot -Parent
$msi=if($DevelopmentUnsigned){Join-Path $PSScriptRoot 'build\development\SurroundForge-0.1.11-x64-UNSIGNED-DEVELOPMENT.msi'}else{Join-Path $root 'dist\SurroundForge-0.1.11-x64.msi'}
if($policy){Test-ReleaseSignature -Path $msi -Policy $policy | Out-Null}
$validation=Join-Path $PSScriptRoot 'validation\0.1.11'
$extract=Join-Path $validation 'extract'
New-Item -ItemType Directory -Path $validation -Force | Out-Null
function Assert($value,[string]$message){if(-not $value){throw $message}}
function Msi-Run([string[]]$arguments,[string]$log) {
  $process=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') -ArgumentList ($arguments+@('/qn','REBOOT=ReallySuppress','/l*v',('"'+(Join-Path $validation $log)+'"'))) -WindowStyle Hidden -Wait -PassThru
  Assert ($process.ExitCode -eq 0) "Windows Installer exit $($process.ExitCode), see $log"
}
function Native-Defaults {
  return ((& (Join-Path $root 'source\engine\build\Release\bridge_control.exe') --defaults) -join "`n")
}
$installer=New-Object -ComObject WindowsInstaller.Installer
$database=$installer.OpenDatabase($msi,0)
function Query([string]$sql) {
  $view=$database.OpenView($sql);[void]$view.Execute();$rows=@()
  while($record=$view.Fetch()){$rows+=$record.StringData(1)}
  [void]$view.Close();return $rows
}
Assert ((Query "SELECT Value FROM Property WHERE Property='ProductVersion'") -eq '0.1.11') 'MSI product version mismatch'
Assert ((Query "SELECT Value FROM Property WHERE Property='ProductName'") -eq 'SurroundForge') 'MSI product name mismatch'
Assert ((Query "SELECT Value FROM Property WHERE Property='Manufacturer'") -eq 'Cracken Released, LLC') 'MSI manufacturer mismatch'
Assert ((Query "SELECT Value FROM Property WHERE Property='UpgradeCode'") -eq '{5F84BC04-1D71-4E51-83D3-2832FCCF20F2}') 'Preserve MSI upgrade identity'
foreach($directory in 'INSTALLFOLDER','AppMenu'){
  Assert (((Query "SELECT DefaultDir FROM Directory WHERE Directory='$directory'") -split '\|')[-1] -eq 'SurroundForge') "Product directory identity mismatch: $directory"
}
function Startup-Fingerprint {
  return ((Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Startup')) -Filter '*.lnk' -File |
    Sort-Object FullName | ForEach-Object {$_.FullName+' '+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join "`n")
}
foreach($identity in @(@('SetupShortcut','SurroundForge Setup'),@('StartShortcut','Start SurroundForge'),@('StopShortcut','Stop SurroundForge'))){
  Assert (((Query ("SELECT Name FROM Shortcut WHERE Shortcut='"+$identity[0]+"'")) -split '\|')[-1] -eq $identity[1]) 'Installed shortcut identity mismatch'
}
Assert (-not (Query "SELECT Value FROM Property WHERE Property='ALLUSERS'")) 'Package must be per-user'
$names=Query 'SELECT FileName FROM File'
foreach($name in 'engine.exe','bridge_control.exe','Setup.ps1','Bridge.ps1','Uninstall.ps1','VBCABLE_Setup_x64.exe','C-Media.zip','vcruntime140.dll','msvcp140.dll') {
  Assert (@($names | Where-Object {($_ -split '\|')[-1] -eq $name}).Count -eq 1) "Missing/duplicate payload file $name"
}
foreach($name in 'bridge.conf','bridge-state.json','bridge.log'){Assert (-not ($names | Where-Object {($_ -split '\|')[-1] -eq $name})) "Laptop configuration/state must not ship: $name"}
Assert ((Query "SELECT Target FROM CustomAction WHERE Action='LaunchSetup'") -match '\[System64Folder\]') 'Use the destination 64-bit PowerShell'
Msi-Run @('/a',('"'+$msi+'"'),('TARGETDIR="'+$extract+'"')) 'extract.log'
$installedRoot=(Get-ChildItem -LiteralPath $extract -Filter 'Bridge.ps1' -Recurse -File | Select-Object -First 1).Directory.FullName
Assert $installedRoot 'Bridge missing after extraction'
foreach($name in 'Bridge.ps1','Setup.ps1') {
  if($policy){
    Test-ReleaseSignature -Path (Join-Path $installedRoot $name) -Policy $policy | Out-Null
    $packaged=[IO.File]::ReadAllText((Join-Path $installedRoot $name)) -replace '(?ms)^# SIG # Begin signature block.*\z',''
    Assert ($packaged.TrimEnd() -ceq [IO.File]::ReadAllText((Join-Path $root $name)).TrimEnd()) "Stale packaged source: $name"
  } else {Assert ((Get-FileHash (Join-Path $installedRoot $name)).Hash -eq (Get-FileHash (Join-Path $root $name)).Hash) "Stale packaged source: $name"}
}
if($policy){
  Test-ReleaseSignature -Path (Join-Path $installedRoot 'Uninstall.ps1') -Policy $policy | Out-Null
  foreach($file in Get-ChildItem -LiteralPath (Join-Path $installedRoot 'Runtime') -File){
    if($file.Name -notmatch '^(msvcp|vcruntime|concrt)'){Test-ReleaseSignature -Path $file.FullName -Policy $policy | Out-Null}
    else {Assert-MicrosoftSigningTool $file.FullName;Invoke-SigningTool $policy.SignToolPath @('verify','/pa','/all','/v',$file.FullName)}
  }
}
# Release 0.1.11 changes packaging/signing, not the verified 0.1.10 audio engine.
$engineVersion=& (Join-Path $installedRoot 'Runtime\engine.exe') --version
Assert ($LASTEXITCODE -eq 0 -and $engineVersion -eq 'SurroundForge 0.1.10-local') 'Packaged engine/runtime version mismatch or dependency load failure'
$devices=(& (Join-Path $installedRoot 'Runtime\bridge_control.exe') --devices-json) | ConvertFrom-Json
Assert ($LASTEXITCODE -eq 0 -and $devices.Count -gt 0) 'Packaged controller/runtime dependency load failed'
Get-ChildItem -LiteralPath (Join-Path $root 'vbcable') -File | ForEach-Object {
  Assert ((Get-FileHash $_.FullName).Hash -eq (Get-FileHash (Join-Path $installedRoot ('Drivers\VB-CABLE\'+$_.Name))).Hash) "Vendor VB package modified: $($_.Name)"
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive=[IO.Compression.ZipFile]::OpenRead((Join-Path $installedRoot 'Drivers\C-Media.zip'))
try {
  $vendorRoot=Join-Path (Split-Path $root -Parent) 'package\WIN10'
  $original=Get-ChildItem -LiteralPath $vendorRoot -Recurse -File
  Assert (@($archive.Entries | Where-Object {$_.Name}).Count -eq $original.Count) 'Incomplete C-Media media'
  foreach($file in $original) {
    $relative=$file.FullName.Substring($vendorRoot.Length+1).Replace('\','/')
    $entry=$archive.GetEntry($relative)
    if(-not $entry){$entry=$archive.GetEntry($relative.Replace('/','\'))}
    Assert $entry "C-Media media missing $relative"
    $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
    try {$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')} finally {$stream.Dispose();$sha.Dispose()}
    Assert ($hash -eq (Get-FileHash $file.FullName).Hash) "C-Media media modified $relative"
  }
} finally {$archive.Dispose()}
Write-Output 'PASS: MSI schema/version, per-user scope, no laptop state, packaged source/runtime and unchanged complete vendor media'
if($InstallRoundTrip) {
  $destination=Join-Path $validation 'installed'
  $before=Native-Defaults
  $startupHash=Startup-Fingerprint
  $didInstall=$false
  $didInstallPrevious=$false
  $previousDestination=Join-Path $validation 'previous'
  try {
    if($UpgradeFromMsi){
      Assert (Test-Path -LiteralPath $UpgradeFromMsi) 'Previous MSI missing for upgrade test'
      # Legacy packages did not remember a custom folder during major upgrade.
      # Exercise their supported default-folder upgrade; exercise custom-folder
      # removal with the new package below, without injecting INSTALLFOLDER.
      $previousDatabase=$installer.OpenDatabase($UpgradeFromMsi,0)
      $previousView=$previousDatabase.OpenView("SELECT DefaultDir FROM Directory WHERE Directory='INSTALLFOLDER'")
      [void]$previousView.Execute();$previousFolder=($previousView.Fetch().StringData(1) -split '\|')[-1];[void]$previousView.Close()
      $previousDestination=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) $previousFolder
      Assert (-not (Test-Path -LiteralPath $previousDestination)) 'Do not replace an existing previous-version folder during this test'
      Msi-Run @('/i',('"'+$UpgradeFromMsi+'"'),'WIXUI_EXITDIALOGOPTIONALCHECKBOX=0') 'previous-install.log'
      $didInstallPrevious=$true
      Assert (Test-Path (Join-Path $previousDestination 'Runtime\engine.exe')) 'Previous version did not install'
      Assert ((Native-Defaults) -eq $before) 'Previous install changed audio defaults'
    }
    Msi-Run @('/i',('"'+$msi+'"'),('INSTALLFOLDER="'+$destination+'"'),'WIXUI_EXITDIALOGOPTIONALCHECKBOX=0') 'install.log'
    $didInstall=$true
    Assert (Test-Path (Join-Path $destination 'Runtime\engine.exe')) 'Install did not deploy runtime'
    Assert ((Native-Defaults) -eq $before) 'Silent MSI install changed audio defaults'
    if($didInstallPrevious){
      Assert (-not (Test-Path (Join-Path $previousDestination 'Runtime\engine.exe'))) 'Upgrade left the previous product runtime installed'
      Write-Output 'PASS: previous product upgraded to the renamed product without duplicate runtime'
    }
  } finally {
    if($didInstall){
      try {Msi-Run @('/x',('"'+$msi+'"')) 'uninstall.log'}
      catch {
        $cleanupFailure=$_
        # Reproducer cleanup only: remove the test-owned custom installation even
        # if normal uninstall forgot its folder, then report the original failure.
        Copy-Item -LiteralPath (Join-Path $validation 'uninstall.log') -Destination (Join-Path $validation 'uninstall-failed.log') -Force
        Msi-Run @('/x',('"'+$msi+'"'),('INSTALLFOLDER="'+$destination+'"')) 'uninstall-fixture-cleanup.log'
        throw $cleanupFailure
      }
    }
    if($didInstallPrevious -and (Test-Path (Join-Path $previousDestination 'Runtime\engine.exe'))){
      Msi-Run @('/x',('"'+$UpgradeFromMsi+'"'),('INSTALLFOLDER="'+$previousDestination+'"')) 'previous-uninstall.log'
    }
  }
  Assert (-not (Test-Path (Join-Path $destination 'Runtime\engine.exe'))) 'Uninstall left MSI-owned runtime'
  Assert ((Native-Defaults) -eq $before) 'Uninstall changed another bridge defaults'
  $afterHash=Startup-Fingerprint
  Assert ($afterHash -eq $startupHash) 'Uninstall changed another installation startup shortcut'
  Write-Output 'PASS: actual MSI install/uninstall; existing audio defaults and startup shortcut preserved'
}
