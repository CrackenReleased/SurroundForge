<#
.SYNOPSIS
  Builds and packages the native Virtual Surround WaveRT audio driver.

.DESCRIPTION
  Compiles the custom kernel-mode WaveRT audio driver (SimpleAudioSample.sys)
  exposing a 6-channel 5.1 surround sound audio endpoint (48 kHz, PCM16/PCM32/float32).
  Requires Visual Studio 2022 and the Windows Driver Kit (WDK).
#>
[CmdletBinding()]
param(
  [ValidateSet('Release', 'Debug')]
  [string]$Configuration = 'Release',

  [ValidateSet('x64', 'ARM64')]
  [string]$Platform = 'x64',

  [switch]$Sign,

  [switch]$VerifyToolchainOnly,

  [string]$WdkBuildRoot = 'C:\Program Files (x86)\Windows Kits\10\build'
)

$ErrorActionPreference = 'Stop'
if ($Sign) { throw 'Publisher signing is not implemented by Build-Driver.ps1. See docs/SIGNING.md.' }
$scriptDir = $PSScriptRoot
$solutionPath = Join-Path $scriptDir 'SimpleAudioSample.sln'

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host " SurroundForge Native Audio Driver Builder" -ForegroundColor Cyan
Write-Host " Configuration: $Configuration | Platform: $Platform" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

# 1. Locate MSBuild
$msbuildCandidates = @(
  'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\amd64\MSBuild.exe',
  'C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\amd64\MSBuild.exe',
  'C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\amd64\MSBuild.exe',
  'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\amd64\MSBuild.exe'
)
$msbuild = $null
if (Get-Command msbuild -ErrorAction SilentlyContinue) {
  $msbuild = (Get-Command msbuild).Source
}
if (-not $msbuild) {
  foreach ($p in $msbuildCandidates) {
    if (Test-Path $p) { $msbuild = $p; break }
  }
}
if (-not $msbuild) {
  throw "MSBuild not found. Install Visual Studio 2022 or VS Build Tools."
}
Write-Host "Using MSBuild: $msbuild" -ForegroundColor Green

# 2. Check for WDK props in both legacy and versioned kit layouts.
$wdkProps = Join-Path $WdkBuildRoot 'WindowsDriver.Default.props'
if (-not (Test-Path -LiteralPath $wdkProps)) {
  $wdkProps = Get-ChildItem -LiteralPath $WdkBuildRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'WindowsDriver.Default.props' } |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
}
if (-not $wdkProps) {
  throw 'Windows Driver Kit (WDK) is not installed. Install a compatible WDK before building the native driver.'
}
Write-Host "Using WDK props: $wdkProps" -ForegroundColor Green
if ($VerifyToolchainOnly) { return }

# 3. Build Driver Solution
Write-Host "Building driver solution..." -ForegroundColor Yellow
& $msbuild $solutionPath /p:Configuration=$Configuration /p:Platform=$Platform /t:Build /m

if ($LASTEXITCODE -ne 0) {
  throw "Driver build failed with exit code $LASTEXITCODE."
}

$outputPackage = Join-Path $scriptDir "$Platform\$Configuration\package"
Write-Host "Driver package built successfully: $outputPackage" -ForegroundColor Green
