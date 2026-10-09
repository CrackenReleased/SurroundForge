[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($value,[string]$message){if(-not $value){throw $message}}
$files=@('README.md','AGENTS.md','changelog.md','docs\BUILD.md','docs\TROUBLESHOOTING.md',
  'surround\Bridge.ps1','surround\Setup.ps1','surround\installer\Build-Msi.ps1',
  'surround\installer\Uninstall.ps1','surround\installer\Test-Msi.ps1',
  'surround\installer\Read Me.txt','surround\installer\Third Party Notices.txt',
  'surround\installer\License.rtf','surround\tests\bridge_test_settings.py')
foreach($file in $files){
  $text=Get-Content -LiteralPath (Join-Path $project $file) -Raw
  Assert ($text -notmatch '(?i)Samsung|HT-D550|\bD\.IN\b') "Receiver-specific identity remains in $file"
}
$build=Get-Content -LiteralPath (Join-Path $project 'surround\installer\Build-Msi.ps1') -Raw
Assert ($build -match 'Name="SurroundForge"') 'MSI product must be SurroundForge'
Assert ($build -match 'Version="0\.1\.11"') 'MSI version must be 0.1.11'
Assert ($build -match 'Manufacturer="Cracken Released, LLC"') 'Use the legal company name in MSI metadata'
Assert ($build -match 'UpgradeCode="5F84BC04-1D71-4E51-83D3-2832FCCF20F2"') 'Preserve the existing MSI upgrade identity'
$bridge=Get-Content -LiteralPath (Join-Path $project 'surround\Bridge.ps1') -Raw
Assert ($bridge -match "'SurroundForge.lnk'") 'Startup identity must match product'
Write-Output "PASS: neutral product identity across $($files.Count) files; stable MSI upgrade identity"
