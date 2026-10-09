$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Bridge.ps1') -Action Stop
$startup=Join-Path ([Environment]::GetFolderPath('Startup')) 'Samsung Optical 5.1.lnk'
if(Test-Path -LiteralPath $startup) {
  $shell=New-Object -ComObject WScript.Shell
  $shortcut=$shell.CreateShortcut($startup)
  if($shortcut.Arguments.Contains((Join-Path $PSScriptRoot 'Bridge.ps1'))) {
    Remove-Item -LiteralPath $startup
  }
}
# Shared vendor drivers are intentionally retained; their own uninstallers own them.
