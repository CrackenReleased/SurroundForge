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
$inx=Get-Content -LiteralPath (Join-Path $project 'surround\source\driver\Source\Main\SimpleAudioSample.inx') -Raw
Assert ($inx -match 'ProviderName\s*=\s*"Cracken Released, LLC"' -and $inx -match 'MfgName\s*=\s*"Cracken Released, LLC"') 'Kernel driver INF must use legal company name Cracken Released, LLC'
Assert ($inx -match 'WaveSpeaker\.szPname\s*=\s*"SurroundForge 5\.1"') 'Kernel driver wave endpoint must be named SurroundForge 5.1'
Assert ($inx -match 'ROOT\\SurroundForgeAudio') 'Kernel driver INF must register ROOT\SurroundForgeAudio hardware ID'
Assert ($inx -match 'PKEY_AudioEndpoint_PhysicalSpeakers.*0x0000003f') 'Kernel driver INF must persist 0x3f 5.1 physical speaker mask'
$topo=Get-Content -LiteralPath (Join-Path $project 'surround\source\driver\Source\Filters\speakertoptable.h') -Raw
Assert ($topo -match 'KSAUDIO_SPEAKER_5POINT1') 'Kernel driver jack topology must report KSAUDIO_SPEAKER_5POINT1 (not stereo)'
$wavTable=Get-Content -LiteralPath (Join-Path $project 'surround\source\driver\Source\Filters\speakerwavtable.h') -Raw
Assert ($wavTable -match 'KSDATAFORMAT_SUBTYPE_IEEE_FLOAT') 'Kernel driver wave table must support 32-bit IEEE float for loopback gain'
Assert (Test-Path -LiteralPath (Join-Path $project 'surround\source\driver\New-AttestationCab.ps1')) 'Attestation CAB packaging script must exist'
# Build prerequisites must fail closed rather than reporting success with no driver.
$builder=Join-Path $project 'surround\source\driver\Build-Driver.ps1'
$fixture={
  function Get-Command { [pscustomobject]@{Source='fixture-msbuild.exe'} }
  function Test-Path { $false }
  function Get-ChildItem { $null }
  $failure=$null
  try { & $builder 6>$null 3>$null } catch { $failure=$_.Exception.Message }
  Assert ($failure -match 'WDK.*not installed|Windows Driver Kit.*not installed') 'Missing WDK must fail the build, not return successfully'
}
& $fixture
Write-Output "PASS: neutral product identity across $($files.Count) files; stable MSI upgrade identity; kernel driver 5.1 & Cracken Released, LLC authority metadata verified"

