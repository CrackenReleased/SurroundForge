# SurroundForge Comprehensive Test Suite Harness
# Usage:
#   .\surround\tests\Invoke-TestSuite.ps1                # Runs all offline unit, mock & regression tests
#   .\surround\tests\Invoke-TestSuite.ps1 -Suite Offline # Explicit offline suite
#   .\surround\tests\Invoke-TestSuite.ps1 -Suite Live    # Runs live audio host tests (requires running engine)
#   .\surround\tests\Invoke-TestSuite.ps1 -Suite All     # Runs full offline + live suite
[CmdletBinding()]
param(
  [ValidateSet('Offline','Live','All')]
  [string]$Suite = 'Offline',
  [switch]$FailFast,
  [int]$CadenceSeconds = 15
)

$ErrorActionPreference = 'Continue'
$rootDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$testDir = Join-Path $rootDir 'surround\tests'
$engineDir = Join-Path $rootDir 'surround\source\engine'
$engineBuildDir = Join-Path $engineDir 'build'

# Locate build & test tools
$cmakePaths = @(
  'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
  'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
  'C:\Program Files\CMake\bin\cmake.exe'
)
$ctestExe = $null
$cmakeExe = $null

if (Get-Command ctest -ErrorAction SilentlyContinue) {
  $ctestExe = (Get-Command ctest).Source
}
if (Get-Command cmake -ErrorAction SilentlyContinue) {
  $cmakeExe = (Get-Command cmake).Source
}

if (-not $cmakeExe) {
  foreach ($p in $cmakePaths) {
    if (Test-Path $p) {
      $cmakeExe = $p
      $ctestCandidate = Join-Path (Split-Path $p) 'ctest.exe'
      if (Test-Path $ctestCandidate) { $ctestExe = $ctestCandidate }
      break
    }
  }
}

$pythonExe = $null
if (Get-Command python -ErrorAction SilentlyContinue) {
  $pythonExe = (Get-Command python).Source
}

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host " SurroundForge Test Suite Runner" -ForegroundColor Cyan
Write-Host " Suite: $Suite | Root: $rootDir" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Invoke-SingleTest {
  param(
    [string]$Name,
    [string]$Category,
    [scriptblock]$Action
  )
  
  Write-Host ("`n--> [{0}] {1}..." -f $Category, $Name) -ForegroundColor Yellow
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $status = 'FAIL'
  $detail = ''
  
  try {
    $out = & $Action 2>&1
    $sw.Stop()
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0 -or $null -eq $exitCode) {
      $status = 'PASS'
      $lastLine = ($out | Where-Object { $_ -match 'PASS|passed|SUCCESS' } | Select-Object -Last 1)
      if ($lastLine) { $detail = $lastLine.ToString().Trim() }
      else { $detail = "Completed in {0:N2}s" -f $sw.Elapsed.TotalSeconds }
      Write-Host ("  [PASS] {0} ({1:N2}s)" -f $Name, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
      if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGreen }
    } else {
      $status = 'FAIL'
      $errLines = ($out | Select-Object -Last 5) -join " "
      $detail = "ExitCode: $exitCode | $errLines"
      Write-Host ("  [FAIL] {0} (Exit {1}, {2:N2}s)" -f $Name, $exitCode, $sw.Elapsed.TotalSeconds) -ForegroundColor Red
      Write-Host "         $detail" -ForegroundColor DarkRed
    }
  } catch {
    $sw.Stop()
    $status = 'FAIL'
    $detail = $_.Exception.Message
    Write-Host ("  [FAIL] {0} ({1})" -f $Name, $detail) -ForegroundColor Red
  }

  $record = [PSCustomObject]@{
    Name      = $Name
    Category  = $Category
    Status    = $status
    Duration  = ("{0:N2}s" -f $sw.Elapsed.TotalSeconds)
    Detail    = $detail
  }
  $results.Add($record)

  if ($FailFast -and $status -eq 'FAIL') {
    throw "Test failed with FailFast enabled: $Name"
  }
}

# --- OFFLINE SUITE ---
if ($Suite -in @('Offline', 'All')) {

  # 1. Repository Hygiene
  Invoke-SingleTest 'Repository Hygiene' 'Hygiene' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_repository_hygiene.ps1')
  }

  # 2. Product Identity
  Invoke-SingleTest 'Product Identity' 'Identity' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_product_identity.ps1')
  }

  # 3. Release Signing Safeguards
  Invoke-SingleTest 'Release Signing Rules' 'Security' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_release_signing.ps1')
  }

  # 4. Startup Identity & Migration
  Invoke-SingleTest 'Startup Identity' 'Lifecycle' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_startup_identity.ps1')
  }

  # 5. Native C++ Unit Tests (CTest / doctest)
  Invoke-SingleTest 'Native C++ Unit Tests (39 cases)' 'Native' {
    $unitTestsExe = Join-Path $engineBuildDir 'Release\unit_tests.exe'
    if (Test-Path $unitTestsExe) {
      & $unitTestsExe
    } elseif ($ctestExe -and (Test-Path $engineBuildDir)) {
      & $ctestExe --test-dir $engineBuildDir -C Release --output-on-failure
    } else {
      throw "unit_tests.exe not found at $unitTestsExe"
    }
  }

  # 6. Bridge Lifecycle Mocks
  Invoke-SingleTest 'Bridge Lifecycle' 'Lifecycle' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_bridge_lifecycle.ps1')
  }

  # 7. Bridge Supervisor & Health
  Invoke-SingleTest 'Bridge Supervisor Resilience' 'Lifecycle' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_bridge_supervisor.ps1')
  }

  # 8. Bridge Portable Configuration
  Invoke-SingleTest 'Bridge Portable Config' 'Config' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_bridge_portable.ps1')
  }

  # 9. Setup Prerequisites & Flow
  Invoke-SingleTest 'Setup Flow & Prerequisites' 'Setup' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_setup.ps1')
  }

  # 10. Setup GUI Form Render
  Invoke-SingleTest 'Setup GUI Form Render' 'Setup' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_setup_render.ps1')
  }

  # 11. Speaker Layout Repair & Queries
  Invoke-SingleTest 'Speaker Layout Repair' 'Audio' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_speaker_layout.ps1')
  }

  # 12. Startup Speaker Layout Verification
  Invoke-SingleTest 'Startup Speaker Layout' 'Audio' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_startup_speaker_layout.ps1')
  }

  # 13. System Tray Status & Mocked Restart
  Invoke-SingleTest 'Tray Controller & Status' 'UI' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_tray.ps1')
  }

  # 14. Bridge Control Python CLI Guards
  if ($pythonExe) {
    Invoke-SingleTest 'Bridge Control CLI Guards' 'Python' {
      & $pythonExe (Join-Path $testDir 'test_bridge_control.py')
    }

    # 15. Six-Channel Audio Roundtrip Isolation
    Invoke-SingleTest '6-Channel Audio Roundtrip' 'Python' {
      & $pythonExe (Join-Path $testDir 'test_channel_roundtrip.py')
    }
  } else {
    Write-Host "  [SKIP] Python not found on PATH; skipping python CLI and channel tests." -ForegroundColor DarkYellow
  }
}

# --- LIVE SUITE ---
if ($Suite -in @('Live', 'All')) {
  Write-Host "`n=== LIVE AUDIO HOST TESTS ===" -ForegroundColor Magenta

  # Live Cadence Test
  Invoke-SingleTest 'Live 48kHz Cadence Delivery' 'Live' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_bridge_recovery_live.ps1') -Run -CadenceOnly -ObservationSeconds $CadenceSeconds
  }

  # Live Health File Contention
  Invoke-SingleTest 'Live Health File Contention' 'Live' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_bridge_recovery_live.ps1') -Run -HealthContentionOnly
  }

  # Live Channel Monitor
  if ($pythonExe) {
    Invoke-SingleTest 'Live 6-Channel Monitor' 'Live' {
      & $pythonExe (Join-Path $testDir 'test_channel_monitor.py')
    }

    # Live Endpoint Volume & Mute
    Invoke-SingleTest 'Live Windows Volume & Mute' 'Live' {
      & $pythonExe (Join-Path $testDir 'test_endpoint_volume.py')
    }
  }

  # Full Crash Recovery Test (briefly restarts owned bridge)
  Invoke-SingleTest 'Live Crash Recovery & Restore' 'Live' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'test_bridge_recovery_live.ps1') -Run
  }
}

# --- SUMMARY REPORT ---
Write-Host "`n================================================================================" -ForegroundColor Cyan
Write-Host " TEST SUITE SUMMARY RESULTS" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

$passedCount = ($results | Where-Object { $_.Status -eq 'PASS' }).Count
$failedCount = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$totalCount = $results.Count

$results | Format-Table -Property Name, Category, Status, Duration -AutoSize

Write-Host "Total: $totalCount | Passed: $passedCount | Failed: $failedCount" -ForegroundColor $(if ($failedCount -eq 0) { 'Green' } else { 'Red' })

if ($failedCount -gt 0) {
  Write-Host "`nFAILED TESTS:" -ForegroundColor Red
  $results | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object {
    Write-Host ("  - {0} [{1}]: {2}" -f $_.Name, $_.Category, $_.Detail) -ForegroundColor Red
  }
  exit 1
} else {
  Write-Host "`nAll $passedCount test suites PASSED successfully." -ForegroundColor Green
  exit 0
}
