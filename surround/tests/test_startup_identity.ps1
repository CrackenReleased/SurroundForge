# Extract ownership/migration helpers without launching or modifying live audio.
[CmdletBinding()]
param([string]$BridgePath='')
if(-not $BridgePath){$BridgePath=Join-Path $PSScriptRoot '..\Bridge.ps1'}
$ErrorActionPreference='Stop'
function Assert($value,[string]$message){if(-not $value){throw $message}}
$bridge=$BridgePath
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($bridge,[ref]$tokens,[ref]$errors)
Assert (-not $errors.Count) 'Bridge must parse'
foreach($name in 'Test-BridgeStartupOwner','Remove-OwnedStartupShortcuts'){
  $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
  Assert $definition "Missing startup migration helper: $name"
  Invoke-Expression $definition.Extent.Text
}
$root='E:\Example\SurroundForge'
$startup=Join-Path $root 'SurroundForge.lnk'
Assert (Test-BridgeStartupOwner '-File "E:\Example\SurroundForge\Bridge.ps1" -Action Start' $root) 'Own startup must match'
Assert (-not (Test-BridgeStartupOwner '-File "E:\Other\Bridge.ps1" -Action Start' $root)) 'Other installation must not match'
Assert (-not (Test-BridgeStartupOwner '-File "E:\Example\SurroundForge\Bridge.ps1.extra" -Action Start' $root)) 'Path-prefix collision must not match'
Assert (-not (Test-BridgeStartupOwner '-File "E:\Example\SurroundForge\Bridge.ps1" -Action Stop' $root)) 'Stop shortcut must not match'
$script:Links=@{}
$script:Links[$startup]='-File "E:\Example\SurroundForge\Bridge.ps1" -Action Start'
$script:Links[(Join-Path $root 'Earlier name.lnk')]=$script:Links[$startup]
$script:Links[(Join-Path $root 'Other installation.lnk')]='-File "E:\Other\Bridge.ps1" -Action Start'
$script:Links[(Join-Path $root 'Unrelated.lnk')]='--launch'
$script:Removed=@()
function Get-ChildItem {foreach($path in $script:Links.Keys){[pscustomobject]@{FullName=$path}}}
function Remove-Item([string]$LiteralPath){$script:Removed+=$LiteralPath}
$shell=New-Object PSObject
$shell | Add-Member ScriptMethod CreateShortcut {param($path) [pscustomobject]@{Arguments=$script:Links[$path]}}
Remove-OwnedStartupShortcuts $shell $startup
Assert ($script:Removed.Count -eq 1 -and $script:Removed[0] -eq (Join-Path $root 'Earlier name.lnk')) 'Migration must remove only the old owned shortcut after keeping the new one'
$script:Removed=@()
Remove-OwnedStartupShortcuts $shell
Assert ($script:Removed.Count -eq 2 -and $script:Removed -contains $startup) 'Disable must remove all and only this installation startup links'
Write-Output 'PASS: renamed startup migration; other installations, unrelated links and exact ownership preserved'
