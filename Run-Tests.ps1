# Quick launcher for SurroundForge Test Suite
[CmdletBinding()]
param(
  [ValidateSet('Offline','Live','All')]
  [string]$Suite = 'Offline',
  [switch]$FailFast,
  [int]$CadenceSeconds = 15
)

& (Join-Path $PSScriptRoot 'surround\tests\Invoke-TestSuite.ps1') -Suite $Suite -FailFast:$FailFast -CadenceSeconds $CadenceSeconds
exit $LASTEXITCODE
