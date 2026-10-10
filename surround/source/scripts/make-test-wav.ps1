<#
.SYNOPSIS
  Generates a 5.1, 48 kHz, 16-bit test WAV with a distinct sine tone per channel,
  using the system ffmpeg. Channel order follows the 5.1 layout: FL FR FC LFE BL BR.

  Tones: FL=200 FR=300 FC=400 LFE=60 BL=600 BR=700 Hz — so you can confirm each
  channel ends up in the right speaker after AC3 decode.
  -Sequential creates a 19-second physical speaker test: one second of silence,
  then each channel alone for two seconds, followed by a one-second gap.
  Default peak amplitude is approximately 5% of full scale in both modes.
#>
[CmdletBinding()]
param(
  [string]$Out = (Join-Path $PSScriptRoot '..\engine\test\test_5p1.wav'),
  [ValidateRange(1,3600)]
  [int]$Duration = 5,
  [switch]$Sequential,
  # FFmpeg's sine source peaks at 1/8 full scale, so 0.4 produces about 5%.
  [ValidateRange(0.01,1.0)]
  [double]$Amplitude = 0.4
)

$ErrorActionPreference = 'Stop'
$Out = [System.IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null

# Build a single -filter_complex with one lavfi sine source per channel, then join to 5.1.
# (One arg, no per-input splatting — that mangles the filter string across shells.)
$freqs = 200,300,400,60,600,700
$channels = 'FL','FR','FC','LFE','BL','BR'
$parts  = @()
$labels = ''
$mapping = @()
$gain = $Amplitude.ToString([System.Globalization.CultureInfo]::InvariantCulture)
$expressions = @()
for ($i = 0; $i -lt $freqs.Count; $i++) {
  if ($Sequential) {
    $start = 1 + 3 * $i
    $end = $start + 2
    $expressions += "($gain/8)*sin(2*PI*$($freqs[$i])*t)*between(t,$start,$end)"
  } else {
    $parts += "sine=frequency=$($freqs[$i]):duration=$($Duration):sample_rate=48000,volume=$gain[a$i]"
  }
  $labels += "[a$i]"
  $mapping += "$i.0-$($channels[$i])"
}
$fc = ($parts -join ';') + ";${labels}join=inputs=$($freqs.Count):channel_layout=5.1:map=$($mapping -join '|')[a]"
if ($Sequential) {
  # Generate all channels from the same sample clock; no EOF/padding interaction
  # between the six sources can truncate a later channel's slot.
  $fc = "aevalsrc=exprs='$($expressions -join '|')':s=48000:d=19:c=5.1[a]"
}

& ffmpeg -y -filter_complex $fc -map '[a]' -c:a pcm_s16le $Out
if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed ($LASTEXITCODE)" }
Write-Host "Wrote $Out"
& ffprobe -hide_banner $Out
if ($LASTEXITCODE -ne 0) { throw "ffprobe failed ($LASTEXITCODE)" }
