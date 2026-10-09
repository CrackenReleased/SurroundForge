# Regression for six channels surviving reboot while their speaker assignments vanish.
# Extract only pure/repair functions; all Core Audio writes are mocked.
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\Bridge.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0]}
foreach($name in 'Test-VirtualMix51','Ensure-VirtualMix51') {
  $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
  if(-not $definition){throw "Missing startup speaker validation: $name"}
  Invoke-Expression $definition.Extent.Text
}
function Assert($condition,$message){if(-not $condition){throw $message}}
function Invoke-Control([string[]]$Arguments) {
  if($Arguments[0] -eq '--set-mix-51') {$script:repairs++;if($script:reject){throw 'Device rejected 5.1'};if(-not $script:unchanged){$script:mask='mask=0x3f'};return}
  if($Arguments[0] -ne '--format'){throw 'Unexpected control operation'}
  return @('channels=6','rate=48000',$script:mask)
}
$inputId='selected-VB-endpoint';$repairs=0;$reject=$false;$unchanged=$false;$mask='mask=0x0'
Assert (-not (Test-VirtualMix51 @('channels=6','rate=48000','mask=0x0'))) 'Regression: unassigned six-channel input accepted as surround'
Assert (-not (Test-VirtualMix51 @('channels=2','rate=48000','mask=0x3f'))) 'Stereo input accepted as surround'
Assert (-not (Test-VirtualMix51 @('channels=6','rate=44100','mask=0x3f'))) 'Wrong sample rate accepted'
Ensure-VirtualMix51 | Out-Null
Assert ($repairs -eq 1 -and $mask -eq 'mask=0x3f') 'Startup did not repair reboot-lost layout'
Ensure-VirtualMix51 | Out-Null
Assert ($repairs -eq 1) 'Already correct layout was changed'
$mask='mask=0x0';$reject=$true;$caught=$false
try {Ensure-VirtualMix51 | Out-Null} catch {$caught=$true}
Assert $caught 'Rejected format must stop startup'
$reject=$false;$unchanged=$true;$caught=$false
try {Ensure-VirtualMix51 | Out-Null} catch {$caught=$true}
Assert $caught 'A successful setter without a corrected readback must stop startup'
Write-Output 'PASS: missing speaker assignments repaired and verified; stereo/rate/rejected or ineffective repairs fail closed; correct layout unchanged.'
