$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Bridge.ps1') -Action Stop
& (Join-Path $PSScriptRoot 'Bridge.ps1') -Action DisableStartup
# Shared vendor drivers are intentionally retained; their own uninstallers own them.
