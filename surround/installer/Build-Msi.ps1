[CmdletBinding()]
param([string]$ReleaseDirectory='', [string]$SigningConfiguration='', [switch]$DevelopmentUnsigned)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Signing.ps1')
# Fail before touching staging or existing release artifacts.
if($DevelopmentUnsigned -and $SigningConfiguration){throw 'Choose signed release or unsigned development, not both.'}
$policy=if(-not $DevelopmentUnsigned){Read-SigningConfiguration $SigningConfiguration}else{$null}
$root=Split-Path $PSScriptRoot -Parent
$stage=Join-Path $PSScriptRoot 'payload'
$work=Join-Path $PSScriptRoot 'build'
$wix=Join-Path $PSScriptRoot 'toolchain\wix'
$dist=if($DevelopmentUnsigned){Join-Path $work 'development'}else{Join-Path $root 'dist'}
$script:SigningLog=Join-Path $work 'signing.log'
if(Test-Path -LiteralPath $stage) {
  if([IO.Path]::GetFullPath($stage) -ne [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'payload'))){throw 'Unsafe staging path'}
  Remove-Item -LiteralPath $stage -Recurse -Force
}
foreach($path in $stage,$work,$dist){New-Item -ItemType Directory -Path $path -Force | Out-Null}
function Copy-Payload($source,$relative) {
  $target=Join-Path $stage $relative
  New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
  Copy-Item -LiteralPath $source -Destination $target -Force
}
foreach($name in 'Bridge.ps1','Setup.ps1'){Copy-Payload (Join-Path $root $name) $name}
Copy-Payload (Join-Path $PSScriptRoot 'Uninstall.ps1') 'Uninstall.ps1'
Copy-Payload (Join-Path $PSScriptRoot 'Read Me.txt') 'Read Me.txt'
Copy-Payload (Join-Path $PSScriptRoot 'Third Party Notices.txt') 'Third Party Notices.txt'
Copy-Payload (Join-Path $root 'source\LICENSE') 'Licenses\Engine-MIT.txt'
Copy-Payload (Join-Path $PSScriptRoot 'LGPL-2.1.txt') 'Licenses\FFmpeg-LGPL-2.1.txt'
Copy-Payload (Join-Path $PSScriptRoot 'FFmpeg-Version.txt') 'Licenses\FFmpeg-Version.txt'
$release=if($ReleaseDirectory){[IO.Path]::GetFullPath($ReleaseDirectory)}else{Join-Path $root 'source\engine\build\Release'}
foreach($name in 'engine.exe','bridge_control.exe'){Copy-Payload (Join-Path $release $name) ('Runtime\'+$name)}
Get-ChildItem -LiteralPath (Join-Path $root 'source\third_party\ffmpeg\bin') -Filter '*.dll' | ForEach-Object {Copy-Payload $_.FullName ('Runtime\'+$_.Name)}
$crt=Get-ChildItem 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT' -Directory | Sort-Object FullName -Descending | Select-Object -First 1
if(-not $crt){throw 'MSVC x64 redistributable runtime files not found.'}
Get-ChildItem -LiteralPath $crt.FullName -Filter '*.dll' | ForEach-Object {Copy-Payload $_.FullName ('Runtime\'+$_.Name)}
# Keep the complete VB-Audio vendor package unchanged, including its readme/license.
Get-ChildItem -LiteralPath (Join-Path $root 'vbcable') -File | ForEach-Object {Copy-Payload $_.FullName ('Drivers\VB-CABLE\'+$_.Name)}
# Preserve all external InstallShield media: its setup INI references SoftwareDriver\InI.
# One embedded ZIP avoids thousands of MSI components for the original language/media files.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$cmZip=Join-Path $stage 'Drivers\C-Media.zip'
New-Item -ItemType Directory -Path (Split-Path $cmZip -Parent) -Force | Out-Null
[IO.Compression.ZipFile]::CreateFromDirectory((Join-Path (Split-Path $root -Parent) 'package\WIN10'),$cmZip,[IO.Compression.CompressionLevel]::Optimal,$false)
$signatureRecords=@()
if($policy){
  [IO.File]::WriteAllText($script:SigningLog,'')
  # A signed driver catalog does not authenticate its installer wrapper. Never
  # re-sign an unsigned vendor installer as if it were our own software.
  Test-VendorInstallerSignature -Path (Join-Path $root 'vbcable\VBCABLE_Setup_x64.exe') -Policy $policy
  Test-VendorInstallerSignature -Path (Join-Path (Split-Path $root -Parent) 'package\WIN10\setup.exe') -Policy $policy
  # Sign only staging copies. Preserve vendor drivers and Microsoft DLL signatures.
  foreach($file in Get-ChildItem -LiteralPath $stage -Filter '*.ps1' -File){
    $signatureRecords+=Invoke-ReleaseSigning -Path $file.FullName -Policy $policy
  }
  foreach($file in Get-ChildItem -LiteralPath (Join-Path $stage 'Runtime') -File){
    $vendorSignature=Get-AuthenticodeSignature -LiteralPath $file.FullName
    if($file.Name -match '^(msvcp|vcruntime|concrt)' ){
      if($vendorSignature.Status -ne 'Valid' -or $vendorSignature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -ne 'Microsoft Corporation'){throw "Invalid Microsoft runtime signature: $($file.Name)"}
      Invoke-SigningTool $policy.SignToolPath @('verify','/pa','/all','/v',$file.FullName)
      $signatureRecords+=[pscustomobject]@{File=$file.Name;SHA256=(Get-FileHash $file.FullName).Hash;Publisher='Microsoft Corporation';Status='Valid'}
    } else {$signatureRecords+=Invoke-ReleaseSigning -Path $file.FullName -Policy $policy}
  }
  $readme=Join-Path $stage 'Read Me.txt'
  $text=[IO.File]::ReadAllText($readme).Replace('This development MSI is unsigned and is not a public release.','This MSI and the SurroundForge executable components are Authenticode-signed by Cracken Released, LLC and timestamped. Verify the publisher before installation.')
  [IO.File]::WriteAllText($readme,$text)
}
function Xml-Escape([string]$value){return [Security.SecurityElement]::Escape($value)}
$files=Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName
$directories=@{''='INSTALLFOLDER'}
$directoryXml=New-Object Text.StringBuilder
$componentXml=New-Object Text.StringBuilder
$featureXml=New-Object Text.StringBuilder
$number=0
foreach($file in $files) {
  $relative=$file.FullName.Substring($stage.Length+1)
  $folder=Split-Path $relative -Parent
  if(-not $directories.ContainsKey($folder)) {
    $parts=$folder.Split('\'); $partial=''
    foreach($part in $parts) {
      $parent=$partial
      $partial=if($partial){$partial+'\'+$part}else{$part}
      if(-not $directories.ContainsKey($partial)) {
        $dirId='Dir'+$directories.Count
        $directories[$partial]=$dirId
        [void]$directoryXml.AppendLine('<DirectoryRef Id="'+$directories[$parent]+'"><Directory Id="'+$dirId+'" Name="'+(Xml-Escape $part)+'" /></DirectoryRef>')
      }
    }
  }
  $number++
  $digest=[Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($relative.ToLowerInvariant()))
  $guid=New-Object Guid (,[byte[]]$digest[0..15])
  $id='File'+$guid.ToString('N')
  [void]$componentXml.AppendLine('<DirectoryRef Id="'+$directories[$folder]+'"><Component Id="Cmp'+$guid.ToString('N')+'" Guid="'+$guid.ToString()+'" Win64="yes"><File Id="'+$id+'" Source="'+(Xml-Escape $file.FullName)+'" Name="'+(Xml-Escape $file.Name)+'" /><RegistryValue Root="HKCU" Key="Software\CrackenReleased\SurroundForge\Files" Name="'+$id+'" Type="integer" Value="1" KeyPath="yes" /></Component></DirectoryRef>')
  [void]$featureXml.AppendLine('<ComponentRef Id="Cmp'+$guid.ToString('N')+'" />')
}
$removeXml=($directories.Values | ForEach-Object {'<RemoveFolder Id="Remove_'+$_+'" Directory="'+$_+'" On="uninstall" />'}) -join ''
$source=@'
<?xml version="1.0" encoding="utf-8"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
<Product Id="*" Name="SurroundForge" Language="1033" Version="0.1.11" Manufacturer="Cracken Released, LLC" UpgradeCode="5F84BC04-1D71-4E51-83D3-2832FCCF20F2">
<Package InstallerVersion="500" Compressed="yes" InstallScope="perUser" Platform="x64" Description="Real-time optical 5.1 audio with Windows volume and mute" />
<MajorUpgrade DowngradeErrorMessage="A newer version of SurroundForge is already installed." />
<MediaTemplate EmbedCab="yes" CompressionLevel="medium" />
<Property Id="WINDOWSREALBUILD"><RegistrySearch Id="ActualWindowsBuild" Root="HKLM" Key="SOFTWARE\Microsoft\Windows NT\CurrentVersion" Name="CurrentBuildNumber" Type="raw" Win64="yes" /></Property>
<Property Id="INSTALLFOLDER"><RegistrySearch Id="SavedInstallFolder" Root="HKCU" Key="Software\CrackenReleased\SurroundForge" Name="InstallFolder" Type="raw" Win64="yes" /></Property>
<Condition Message="SurroundForge requires 64-bit Windows 10 or 11.">VersionNT64 AND WINDOWSREALBUILD &gt;= 10240</Condition>
<Property Id="MSIRESTARTMANAGERCONTROL" Value="Disable" />
<Directory Id="TARGETDIR" Name="SourceDir"><Directory Id="LocalAppDataFolder"><Directory Id="INSTALLFOLDER" Name="SurroundForge" /></Directory><Directory Id="ProgramMenuFolder"><Directory Id="AppMenu" Name="SurroundForge" /></Directory></Directory>
DIRECTORIES
COMPONENTS
<DirectoryRef Id="AppMenu"><Component Id="MenuShortcuts" Guid="*" Win64="yes">
<Shortcut Id="SetupShortcut" Name="SurroundForge Setup" Target="[SystemFolder]WindowsPowerShell\v1.0\powershell.exe" Arguments="-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;[INSTALLFOLDER]Setup.ps1&quot;" WorkingDirectory="INSTALLFOLDER" />
<Shortcut Id="StartShortcut" Name="Start SurroundForge" Target="[SystemFolder]WindowsPowerShell\v1.0\powershell.exe" Arguments="-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;[INSTALLFOLDER]Bridge.ps1&quot; -Action Start" WorkingDirectory="INSTALLFOLDER" />
<Shortcut Id="StopShortcut" Name="Stop SurroundForge" Target="[SystemFolder]WindowsPowerShell\v1.0\powershell.exe" Arguments="-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;[INSTALLFOLDER]Bridge.ps1&quot; -Action Stop" WorkingDirectory="INSTALLFOLDER" />
<RemoveFolder Id="RemoveAppMenu" On="uninstall" />REMOVEFOLDERS<RegistryValue Root="HKCU" Key="Software\CrackenReleased\SurroundForge" Name="Installed" Type="integer" Value="1" KeyPath="yes" /><RegistryValue Root="HKCU" Key="Software\CrackenReleased\SurroundForge" Name="InstallFolder" Type="string" Value="[INSTALLFOLDER]" /></Component></DirectoryRef>
<Feature Id="Complete" Title="SurroundForge" Level="1">FEATURES<ComponentRef Id="MenuShortcuts" /></Feature>
<CustomAction Id="LaunchSetup" Directory="INSTALLFOLDER" ExeCommand="&quot;[SystemFolder]WindowsPowerShell\v1.0\powershell.exe&quot; -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;[INSTALLFOLDER]Setup.ps1&quot;" Execute="immediate" Return="asyncNoWait" Impersonate="yes" />
<CustomAction Id="CleanupBridge" Directory="INSTALLFOLDER" ExeCommand="&quot;[SystemFolder]WindowsPowerShell\v1.0\powershell.exe&quot; -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;[INSTALLFOLDER]Uninstall.ps1&quot;" Execute="immediate" Return="check" Impersonate="yes" />
<InstallExecuteSequence><Custom Action="CleanupBridge" Before="RemoveFiles">Installed AND REMOVE~="ALL"</Custom></InstallExecuteSequence>
<Property Id="WIXUI_EXITDIALOGOPTIONALCHECKBOXTEXT" Value="Open SurroundForge Setup" /><Property Id="WIXUI_EXITDIALOGOPTIONALCHECKBOX" Value="1" />
<WixVariable Id="WixUILicenseRtf" Value="LICENSEPATH" /><UIRef Id="WixUI_Minimal" />
<UI><Publish Dialog="ExitDialog" Control="Finish" Event="DoAction" Value="LaunchSetup">WIXUI_EXITDIALOGOPTIONALCHECKBOX = 1 AND NOT Installed</Publish></UI>
</Product></Wix>
'@
$source=$source.Replace('DIRECTORIES',$directoryXml.ToString()).Replace('COMPONENTS',$componentXml.ToString()).Replace('FEATURES',$featureXml.ToString()).Replace('REMOVEFOLDERS',$removeXml).Replace('LICENSEPATH',(Xml-Escape (Join-Path $PSScriptRoot 'License.rtf'))).Replace('[SystemFolder]WindowsPowerShell','[System64Folder]WindowsPowerShell')
$wxs=Join-Path $work 'SurroundForge.wxs'
[IO.File]::WriteAllText($wxs,$source)
& (Join-Path $wix 'candle.exe') -nologo -arch x64 -out (Join-Path $work 'SurroundForge.wixobj') $wxs
if($LASTEXITCODE){throw 'MSI compilation failed.'}
$msi=Join-Path $work 'SurroundForge-0.1.11-x64.msi'
# ICE91 warns about per-machine use of user-profile files. This MSI is explicitly
# per-user and Test-Msi asserts ALLUSERS absent; keep all other ICE validations.
& (Join-Path $wix 'light.exe') -nologo -sice:ICE91 -ext (Join-Path $wix 'WixUIExtension.dll') -out $msi (Join-Path $work 'SurroundForge.wixobj')
if($LASTEXITCODE){throw 'MSI linking/validation failed.'}
if($policy){$signatureRecords+=Invoke-ReleaseSigning -Path $msi -Policy $policy}
# A signing failure leaves only a private build artifact, never a release MSI.
$outputName=if($DevelopmentUnsigned){'SurroundForge-0.1.11-x64-UNSIGNED-DEVELOPMENT.msi'}else{'SurroundForge-0.1.11-x64.msi'}
$published=Join-Path $dist $outputName
if((Test-Path -LiteralPath $published) -and -not $DevelopmentUnsigned){throw "Refusing to overwrite an existing release artifact: $published"}
$pending=$published+'.pending'
if(Test-Path -LiteralPath $pending){throw "An interrupted publication needs review: $pending"}
if($policy){
  [IO.File]::WriteAllText(($msi+'.signatures.json'),($signatureRecords | ConvertTo-Json -Depth 5))
}
try {
  Copy-Item -LiteralPath $msi -Destination $pending
  if((Get-FileHash $pending).Hash -ne (Get-FileHash $msi).Hash){throw 'Published copy differs from verified MSI.'}
  if($DevelopmentUnsigned){Move-Item -LiteralPath $pending -Destination $published -Force}
  else {Move-Item -LiteralPath $pending -Destination $published}
} finally {if(Test-Path -LiteralPath $pending){Remove-Item -LiteralPath $pending}}
if($policy){Copy-Item -LiteralPath ($msi+'.signatures.json') -Destination ($published+'.signatures.json')}
$msi=$published
$hash=Get-FileHash -LiteralPath $msi -Algorithm SHA256
[IO.File]::WriteAllText(($msi+'.sha256'),$hash.Hash+'  '+[IO.Path]::GetFileName($msi)+[Environment]::NewLine)
Write-Output "Built $msi ($number payload files). SHA256: $($hash.Hash)"
