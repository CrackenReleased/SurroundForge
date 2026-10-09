[CmdletBinding()]
param([switch]$InstallRoundTrip)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$msi=Join-Path $root 'dist\Samsung-Optical-5.1-0.1.9-x64.msi'
$validation=Join-Path $PSScriptRoot 'validation'
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
Assert ((Query "SELECT Value FROM Property WHERE Property='ProductVersion'") -eq '0.1.9') 'MSI product version mismatch'
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
  Assert ((Get-FileHash (Join-Path $installedRoot $name)).Hash -eq (Get-FileHash (Join-Path $root $name)).Hash) "Stale packaged source: $name"
}
& (Join-Path $installedRoot 'Runtime\engine.exe') --version
Assert ($LASTEXITCODE -eq 0) 'Packaged engine/runtime dependency load failed'
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
  $startup=Join-Path ([Environment]::GetFolderPath('Startup')) 'Samsung Optical 5.1.lnk'
  $startupHash=if(Test-Path $startup){(Get-FileHash $startup).Hash}else{''}
  $didInstall=$false
  try {
    Msi-Run @('/i',('"'+$msi+'"'),('INSTALLFOLDER="'+$destination+'"'),'WIXUI_EXITDIALOGOPTIONALCHECKBOX=0') 'install.log'
    $didInstall=$true
    Assert (Test-Path (Join-Path $destination 'Runtime\engine.exe')) 'Install did not deploy runtime'
    Assert ((Native-Defaults) -eq $before) 'Silent MSI install changed audio defaults'
  } finally {
    if($didInstall){Msi-Run @('/x',('"'+$msi+'"'),('INSTALLFOLDER="'+$destination+'"')) 'uninstall.log'}
  }
  Assert (-not (Test-Path (Join-Path $destination 'Runtime\engine.exe'))) 'Uninstall left MSI-owned runtime'
  Assert ((Native-Defaults) -eq $before) 'Uninstall changed another bridge defaults'
  $afterHash=if(Test-Path $startup){(Get-FileHash $startup).Hash}else{''}
  Assert ($afterHash -eq $startupHash) 'Uninstall changed another installation startup shortcut'
  Write-Output 'PASS: actual MSI install/uninstall; existing audio defaults and startup shortcut preserved'
}
