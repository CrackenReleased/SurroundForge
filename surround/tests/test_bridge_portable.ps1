# Exercise the actual bootstrap statements without launching any audio/process commands.
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\Bridge.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0]}
$bootstrap=New-Object Text.StringBuilder
foreach($statement in $ast.EndBlock.Statements) {
  if($statement -is [Management.Automation.Language.FunctionDefinitionAst]){break}
  [void]$bootstrap.AppendLine($statement.Extent.Text.Replace('$PSScriptRoot','$fixture'))
}
$fixture=Join-Path $PSScriptRoot 'output\portable-bootstrap'
$absolute=[IO.Path]::GetFullPath($fixture)
if(-not $absolute.StartsWith([IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'output'))+[IO.Path]::DirectorySeparatorChar)){throw 'Unsafe fixture path'}
try {
  New-Item -ItemType Directory -Path (Join-Path $fixture 'Runtime') -Force | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $fixture 'Runtime\engine.exe'),[byte[]]@())
  [IO.File]::WriteAllText((Join-Path $fixture 'bridge.conf'),"in_id=destination-virtual`r`nout_id=destination-optical`r`n")
  Invoke-Expression $bootstrap.ToString()
  if($inputId -ne 'destination-virtual' -or $outputId -ne 'destination-optical'){throw 'Copied laptop device IDs instead of destination configuration'}
  if($build -ne (Join-Path $fixture 'Runtime')){throw 'Installed layout still depends on a developer build tree'}
  Remove-Item -LiteralPath (Join-Path $fixture 'bridge.conf')
  Invoke-Expression $bootstrap.ToString()
  if($inputId -or $outputId){throw 'Missing configuration must not invent laptop device IDs'}
  Write-Output 'PASS: destination device IDs, installed runtime layout and unconfigured first install'
} finally {
  if(Test-Path -LiteralPath $absolute){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
