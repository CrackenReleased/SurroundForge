# Execute the actual harness summary in a child process; one failing suite must fail CI.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-TestSuite.ps1') -Raw
$marker='# --- SUMMARY REPORT ---'
$offset=$source.IndexOf($marker)
if($offset -lt 0){throw 'Harness summary missing'}
$summary=$source.Substring($offset)
foreach($scenario in @(
  @{Statuses=@('FAIL'); Exit=1},
  @{Statuses=@('PASS','FAIL'); Exit=1},
  @{Statuses=@('FAIL','FAIL'); Exit=1},
  @{Statuses=@('PASS'); Exit=0}
)) {
  $setup='$results = [System.Collections.Generic.List[PSCustomObject]]::new();' + "`n"
  foreach($status in $scenario.Statuses) {
    $setup += '$results.Add([pscustomobject]@{Name="fixture";Category="fixture";Status="' + $status + '";Duration="0s";Detail="fixture"});' + "`n"
  }
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($setup+$summary))
  & powershell -NoProfile -EncodedCommand $encoded *> $null
  if($LASTEXITCODE -ne $scenario.Exit){throw "Summary exit $LASTEXITCODE for $($scenario.Statuses -join ','); expected $($scenario.Exit)"}
}
Write-Output 'PASS: actual suite summary rejects one or multiple failures and accepts a single success.'