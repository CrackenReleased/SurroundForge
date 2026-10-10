<#
.SYNOPSIS
  Packages the SurroundForge 5.1 WaveRT kernel driver into a Microsoft Partner Center
  Hardware Dashboard attestation submission .cab archive.
#>
[CmdletBinding()]
param(
  [string]$DriverPackageDir = '',
  [string]$OutputCabPath = '',
  [switch]$VerifySourceOnly
)
$ErrorActionPreference = 'Stop'
$driverRoot = $PSScriptRoot
$inxPath = Join-Path $driverRoot 'Source\Main\SimpleAudioSample.inx'
$rcPath = Join-Path $driverRoot 'Source\Main\SimpleAudioSample.rc'
$topoPath = Join-Path $driverRoot 'Source\Filters\speakertoptable.h'
$wavePath = Join-Path $driverRoot 'Source\Filters\speakerwavtable.h'

foreach ($required in @($inxPath, $rcPath, $topoPath, $wavePath)) {
  if (-not (Test-Path -LiteralPath $required)) {
    throw "Required kernel driver source file missing: $required"
  }
}

$inxText = Get-Content -LiteralPath $inxPath -Raw
if ($inxText -notmatch 'ProviderName\s*=\s*"Cracken Released, LLC"' -or
    $inxText -notmatch 'SimpleAudioSample\.WaveSpeaker\.szPname\s*=\s*"SurroundForge 5\.1"' -or
    $inxText -notmatch 'PKEY_AudioEndpoint_PhysicalSpeakers.*0x0000003f') {
  throw 'SimpleAudioSample.inx does not have the required Cracken Released, LLC / SurroundForge 5.1 / 0x3f 5.1 metadata.'
}

if ($VerifySourceOnly) {
  Write-Output 'PASS: SurroundForge 5.1 kernel driver source and INF metadata verified (source only; no build or signature validation).'
  exit 0
}

if (-not $DriverPackageDir) {
  $DriverPackageDir = Join-Path $driverRoot 'x64\Release\package'
}
if (-not (Test-Path -LiteralPath $DriverPackageDir)) {
  throw "Built driver package directory not found at '$DriverPackageDir'. Build SimpleAudioSample.sln with WDK 10 first, or pass -VerifySourceOnly."
}

$sysFile = Join-Path $DriverPackageDir 'SimpleAudioSample.sys'
$infFile = Join-Path $DriverPackageDir 'SimpleAudioSample.inf'
if (-not (Test-Path -LiteralPath $sysFile) -or -not (Test-Path -LiteralPath $infFile)) {
  throw "Driver package directory '$DriverPackageDir' must contain SimpleAudioSample.sys and SimpleAudioSample.inf."
}

if (-not $OutputCabPath) {
  $OutputCabPath = Join-Path $driverRoot 'x64\Release\SurroundForge-Driver-Attestation.cab'
}
$cabDir = Split-Path -Path $OutputCabPath -Parent
$cabName = Split-Path -Path $OutputCabPath -Leaf
New-Item -ItemType Directory -Path $cabDir -Force | Out-Null

$ddfPath = Join-Path $cabDir 'attestation.ddf'
$catFile = Join-Path $DriverPackageDir 'SimpleAudioSample.cat'
$ddfLines = @(
  '.OPTION EXPLICIT',
  ('.Set CabinetNameTemplate="' + $cabName + '"'),
  ('.Set DiskDirectoryTemplate="' + $cabDir + '"'),
  '.Set CompressionType=MSZIP',
  '.Set Cabinet=on',
  '.Set Compress=on',
  '.Set DestinationDir=SurroundForgeDriver',
  ('"' + $infFile + '"'),
  ('"' + $sysFile + '"')
)
if (Test-Path -LiteralPath $catFile) {
  $ddfLines += ('"' + $catFile + '"')
}
[IO.File]::WriteAllLines($ddfPath, $ddfLines, (New-Object Text.UTF8Encoding($false)))

$makecab = Join-Path $env:WINDIR 'System32\makecab.exe'
& $makecab /F $ddfPath | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputCabPath)) {
  throw "makecab.exe failed to create attestation cabinet: $OutputCabPath"
}
Write-Output "Created attestation submission cabinet (unsigned): $OutputCabPath"
