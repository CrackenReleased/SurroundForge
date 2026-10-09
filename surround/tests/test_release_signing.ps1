[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$installer=Join-Path (Split-Path $PSScriptRoot -Parent) 'installer'
function Assert($condition,[string]$message){if(-not $condition){throw $message}}
function Reject([scriptblock]$action,[string]$reason){
  try {& $action | Out-Null} catch {
    Assert ($_.Exception.Message -match $reason) "Unexpected rejection: $($_.Exception.Message)"
    return
  }
  throw "Expected rejection: $reason"
}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $installer 'Build-Msi.ps1'),[ref]$tokens,[ref]$errors)
$names=@($ast.ParamBlock.Parameters | ForEach-Object {$_.Name.VariablePath.UserPath})
Assert ($names -contains 'SigningConfiguration' -and $names -contains 'DevelopmentUnsigned') 'Release builder lacks a required signing gate and separate unsigned development mode'
. (Join-Path $installer 'Signing.ps1')
Reject {Read-SigningConfiguration ''} 'Signing configuration is required'
Reject {& (Join-Path $installer 'Build-Msi.ps1') -DevelopmentUnsigned -SigningConfiguration 'unused'} 'Choose signed release or unsigned development'
Reject {Assert-ReleaseSignatureFacts 'Valid' 'Other Publisher' $true 'ABC' @('ABC') $false} 'publisher'
Reject {Assert-ReleaseSignatureFacts 'NotSigned' 'Cracken Released, LLC' $true 'ABC' @('ABC') $false} 'NotSigned'
Reject {Assert-ReleaseSignatureFacts 'Valid' 'Cracken Released, LLC' $false 'ABC' @('ABC') $false} 'timestamp'
Reject {Assert-ReleaseSignatureFacts 'Valid' 'Cracken Released, LLC' $true 'DEF' @('ABC') $false} 'root'
Reject {Assert-ReleaseSignatureFacts 'Valid' 'Cracken Released, LLC' $true 'ABC' @('ABC') $true} 'Self-signed'
Assert-ReleaseSignatureFacts 'Valid' 'Cracken Released, LLC' $true 'ABC' @('ABC') $false

# SignTool's warning exit code (2), including timestamp failures, must be fatal.
$script:SigningLog=$null
Reject {Invoke-SigningTool (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile','-Command','exit 2')} 'exit 2'
function Invoke-SigningTool([string]$Tool,[string[]]$Arguments){$script:LastSigningArguments=$Arguments;throw 'SignTool failed (exit 2)'}
$policy=[pscustomobject]@{Provider='CertificateStore';CertificateThumbprint=('A'*40);StoreLocation='CurrentUser';TimestampUrl='https://timestamp.digicert.com';SignToolPath='fixture'}
Reject {Invoke-ReleaseSigning -Path 'fixture.exe' -Policy $policy} 'exit 2'
Assert (($script:LastSigningArguments -join ' ') -match '/fd SHA256 /tr https://timestamp.digicert.com /td SHA256') 'Require SHA256 file digest and RFC3161 timestamp'
Assert (($script:LastSigningArguments -join ' ') -match '/sha1 A{40} fixture.exe$') 'Select the exact signing identity and exact file'
$artifactPolicy=[pscustomobject]@{Provider='ArtifactSigning';TimestampUrl='http://timestamp.acs.microsoft.com';SignToolPath='fixture';DlibPath='official-x64.dll';MetadataPath='metadata.json'}
Reject {Invoke-ReleaseSigning -Path 'fixture.exe' -Policy $artifactPolicy} 'exit 2'
Assert (($script:LastSigningArguments -join ' ') -match '/dlib official-x64.dll /dmdf metadata.json fixture.exe$') 'Use the selected managed-signing profile metadata'

# Exercise Windows' actual Authenticode implementation on a known unsigned artifact.
# This does not install a certificate or alter any trust store.
$unsigned=Join-Path $PSScriptRoot 'output\unsigned-signature-fixture.ps1'
New-Item -ItemType Directory -Path (Split-Path $unsigned -Parent) -Force | Out-Null
try {
  [IO.File]::WriteAllText($unsigned,"Write-Output 'unsigned fixture'`r`n")
  $facts=Get-AuthenticodeSignature -LiteralPath $unsigned
  Assert ($facts.Status -eq 'NotSigned') 'Unsigned fixture should be NotSigned'
  Reject {Test-ReleaseSignature -Path $unsigned -Policy $policy} 'NotSigned'
  Reject {Test-VendorInstallerSignature -Path $unsigned -Policy $policy} 'Vendor installer is NotSigned'
} finally {if(Test-Path -LiteralPath $unsigned){Remove-Item -LiteralPath $unsigned}}

# A real signed Windows binary modified after signing must also be rejected.
# Work only on the disposable copy; never execute or mutate the system binary.
$tampered=Join-Path $PSScriptRoot 'output\tampered-signature-fixture.exe'
$systemTool=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
try {
  Assert ((Get-AuthenticodeSignature -LiteralPath $systemTool).Status -eq 'Valid') 'The system fixture must start with a valid signature'
  Copy-Item -LiteralPath $systemTool -Destination $tampered
  $bytes=[IO.File]::ReadAllBytes($tampered)
  $bytes[0x400]=$bytes[0x400] -bxor 1
  [IO.File]::WriteAllBytes($tampered,$bytes)
  Assert ((Get-AuthenticodeSignature -LiteralPath $tampered).Status -ne 'Valid') 'Tampering must invalidate Authenticode'
  Reject {Test-ReleaseSignature -Path $tampered -Policy $policy} 'Release signature is'
} finally {if(Test-Path -LiteralPath $tampered){Remove-Item -LiteralPath $tampered}}

# The default command must fail before any staging, build or dist mutation.
$dist=Join-Path (Split-Path $installer -Parent) 'dist'
$before=@(Get-ChildItem -LiteralPath $dist -File | ForEach-Object {$_.Name+':'+(Get-FileHash $_.FullName).Hash}) -join '|'
Reject {& (Join-Path $installer 'Build-Msi.ps1')} 'Signing configuration is required'
$after=@(Get-ChildItem -LiteralPath $dist -File | ForEach-Object {$_.Name+':'+(Get-FileHash $_.FullName).Hash}) -join '|'
Assert ($before -eq $after) 'Rejected release changed existing dist artifacts'
Write-Output 'PASS: release defaults reject missing signing; unsigned/tampered/wrong publisher/missing timestamp/unapproved root/self-signing/vendor wrapper/warning exits rejected; both signing adapters checked; no dist mutation'
