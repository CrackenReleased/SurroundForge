# Mock-only regression. AST-extract functions/branches; never execute the live script.
$ErrorActionPreference='Stop'
$scriptPath=Join-Path $PSScriptRoot '..\Bridge.ps1'
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0]}
$functions=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)
foreach($definition in $functions){Invoke-Expression $definition.Extent.Text}
$stopBranch=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match "^if\(\`$Action -eq 'Stop'\)"},$false)[0].Clauses[0].Item2
$startupCatch=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.TryStatementAst]},$false) | Select-Object -Last 1
$catchText=$startupCatch.CatchClauses[0].Body.Extent.Text
function Branch-Text($node){$text=$node.Extent.Text;return ($text.Substring(1,$text.Length-2) -replace '(?m)^\s*exit\s*$','')}
$stopBlock=[scriptblock]::Create((Branch-Text $stopBranch))
$catchBlock=[scriptblock]::Create("try { throw 'original startup failure' } catch $catchText")

# Replace every side-effecting operation reached by the extracted code.
function Invoke-Control([string[]]$Arguments) {
  if($Arguments[0] -eq '--defaults') {if($script:queryFails){throw 'query failed'};return $script:currentLines}
  $script:attempted+= $Arguments[2]
  if($script:failedRoles -contains $Arguments[2]){throw 'saved endpoint disconnected'}
}
function Stop-Process {param($Id) $script:stopped+= $Id}
function Test-Path {param($LiteralPath) return $true}
function Remove-Item {param($LiteralPath) $script:removed=$true}
function Set-Content {param($LiteralPath,$Encoding,[Parameter(ValueFromPipeline=$true)]$Value) process {$script:saved=$Value}}
function Get-Process {param($Id,$ErrorAction) return $script:fakeProcess}
function Assert($condition,[string]$message){if(-not $condition){throw $message}}
function Reset-Fixture {
  $script:inputId='virtual';$script:engine='owned.exe';$script:statePath='mock-state.json'
  $script:attempted=@();$script:stopped=@();$script:removed=$false;$script:saved=$null;$script:queryFails=$false
  $script:failedRoles=@('0');$script:currentLines=@('0=virtual','1=virtual','2=headset')
  $script:fakeProcess=[pscustomobject]@{Id=42;Path='owned.exe';StartTime=[datetime]'2026-10-09T12:00:00Z';HasExited=$false}
  $script:fakeProcess | Add-Member ScriptMethod Refresh {}
  $script:process=$script:fakeProcess
  $script:state=[pscustomobject]@{processId=42;startedTicks=$script:fakeProcess.StartTime.ToUniversalTime().Ticks;roles=@('0','1');defaults=[pscustomobject]@{'0'='disconnected';'1'='speaker';'2'='headset'}}
  $script:defaults=@{'0'='disconnected';'1'='speaker';'2'='headset'};$script:roles=@('0','1')
  # Startup owns a newly constructed hashtable; Stop owns deserialized JSON properties.
  $script:newState=[pscustomobject]@{processId=42;startedTicks=$script:state.startedTicks;roles=$script:roles;defaults=$script:defaults}
  $script:owned=Find-OwnedProcess $script:state
}

Reset-Fixture
try {& $stopBlock | Out-Null} catch {$script:stopError=$_}
Assert ($script:stopped -contains 42) 'Stop regression: disconnected endpoint prevented owned encoder cleanup'
Assert ($script:attempted -contains '1') 'Stop regression: failure prevented other role restoration'
Assert (-not $script:removed) 'Stop regression: unresolved rollback state was deleted'
$pending=$script:saved | ConvertFrom-Json
Assert (@($pending.roles).Count -eq 1 -and $pending.roles[0] -eq '0') 'Stop must retain only unresolved roles'

Reset-Fixture
try {& $catchBlock | Out-Null} catch {$script:startupError=$_}
Assert ($script:stopped -contains 42) 'Startup catch regression: rollback failure prevented encoder cleanup'
Assert ($script:attempted -contains '1') 'Startup catch regression: rollback failure skipped remaining role'
Assert (-not $script:removed) 'Startup catch must retain unresolved rollback state'
Assert ($script:startupError.Exception.Message -eq 'original startup failure') 'Startup catch must preserve original failure'

Reset-Fixture
$script:fakeProcess.Path='unrelated.exe';$script:owned=Find-OwnedProcess $script:state
Assert (-not $script:owned) 'Reused PID must not count as owned'
& $stopBlock | Out-Null
Assert ($script:stopped.Count -eq 0) 'Must never stop a process with a reused PID'

Reset-Fixture
$script:failedRoles=@();$script:currentLines=@('0=virtual','1=manually-changed','2=headset')
& $stopBlock | Out-Null
Assert ($script:attempted.Count -eq 1 -and $script:attempted[0] -eq '0') 'Preserve manually selected defaults'
Assert ($script:removed -and $script:stopped -contains 42) 'Successful cleanup removes rollback state'

Reset-Fixture
$script:queryFails=$true
& $stopBlock | Out-Null
Assert ($script:stopped -contains 42) 'Defaults query failure must still stop owned encoder'
Assert (-not $script:removed) 'Defaults query failure must preserve state for retry'
Write-Output 'PASS: Stop and startup rollback failures clean up owned encoder, continue roles, preserve unresolved state; reused PID/user defaults guarded'
