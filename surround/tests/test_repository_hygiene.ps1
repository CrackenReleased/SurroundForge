# Regression: the source snapshot must not contain host state or binary dependencies.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$files=@(& git -c core.fsmonitor=false -C $repo ls-files)
if($LASTEXITCODE -ne 0 -or -not $files.Count){throw 'Stage or commit the repository before running this check.'}
$badPaths=@($files | Where-Object {$_ -match '\.(exe|dll|lib|obj|pdb|msi|zip|evtx|reg|wav|ac3|spdif|log|pfx|p12|pem|key)$' -or
  $_ -match '(^|/)(diagnostics|dist|output|build|toolchain|package|vbcable|\.local)(/|$)' -or
  $_ -match '(^|/)(bridge\.conf|bridge-state\.json|channel-activity\.csv|INSTALLATION\.md|what_and_how_log\.md)$'})
if($badPaths.Count){throw "Private/generated files tracked: $($badPaths -join ', ')"}
foreach($file in $files) {
  # Inspect what Git would commit, even if the working copy differs from the index.
  $text=((& git -C $repo show (':'+$file)) -join "`n")
  if($LASTEXITCODE -ne 0){throw "Cannot inspect staged content of $file"}
  if($text -match '\{0\.0\.[01]\.00000000\}\.\{[0-9a-fA-F-]{36}\}' -or
     $text -match '(?i)[CE]:[\\/]Users[\\/][^\\/\s"'']+') {throw "Machine-specific endpoint or user-profile path in $file"}
}
$gitlinks=@(& git -c core.fsmonitor=false -C $repo ls-files --stage | Where-Object {$_ -match '^160000 '})
if($gitlinks.Count){throw 'Embedded Git repository accidentally staged as a submodule.'}
foreach($example in 'surround/bridge.conf','surround/bridge-state.json','surround/channel-activity.csv',
  'surround/diagnostics/example/snapshot.txt','surround/installer/payload/Bridge.ps1','surround/source/engine/build/Release/engine.exe',
  '.local/upstream-source.git/config','.local/signing/signing.json','.local/signing/artifact-metadata.json',
  'surround/installer/private-signing.json','surround/installer/private-certificate.pfx',
  'package/WIN10/Setup.exe','surround/dist/example.msi') {
  & git -c core.fsmonitor=false -C $repo check-ignore --quiet -- $example
  if($LASTEXITCODE -ne 0){throw "Ignore rule missing for $example"}
}
Write-Output "PASS: $($files.Count) source/documentation files; no laptop IDs/user paths, private state, binaries or embedded Git links; generated/private exclusions verified."
