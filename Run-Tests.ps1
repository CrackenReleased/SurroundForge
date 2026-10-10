# Quick launcher for SurroundForge Test Suite
[CmdletBinding()]
param(
  [ValidateSet('Offline','Live','All')]
  [string]$Suite = 'Offline',
  [switch]$FailFast,
  [int]$CadenceSeconds = 15,
  [string]$EngineBuildDirectory = ''
)

& (Join-Path $PSScriptRoot 'surround\tests\Invoke-TestSuite.ps1') -Suite $Suite -FailFast:$FailFast -CadenceSeconds $CadenceSeconds -EngineBuildDirectory $EngineBuildDirectory
exit $LASTEXITCODE
