# SurroundForge

**Forge real PC surround sound through an ordinary USB optical adapter.**

Working release: **v0.1.10**. Gaming surround was confirmed by the user through the USB optical adapter after the reboot speaker-layout repair.

```text
Game / Windows audio
    → VB-CABLE configured as six assigned speakers
    → WASAPI loopback + Windows volume/mute
    → real-time AC3 encoder
    → optical S/PDIF
    → receiver → 5.1 speakers
```

SurroundForge enables a USB optical adapter to carry real-time compressed 5.1 from games and Windows audio. It uses signed audio drivers and a native userspace encoder. The connected receiver must decode AC3 (Dolby Digital) over its optical input; it does not need to be a particular brand. The adapter must support encoded S/PDIF output. The original USB hardware was verified; other adapter combinations have not been independently tested. Ordinary stereo sources stay stereo; it does not fake game surround by enabling stereo upmixing.

## Install and use

The locally built installer is `surround/dist/SurroundForge-0.1.10-x64.msi`. MSI files are release artifacts and are excluded from Git.

1. Install on Windows 10/11 x64 and open **SurroundForge Setup**.
2. Connect the adapter's optical OUT to the receiver's optical IN; select the receiver's optical input.
3. Install missing vendor drivers using Setup. Restart if requested. In C-Media/Xear settings, enable **SPDIF Out**.
4. Select the physical optical output, then **Save and start surround**. Enable startup if desired.
5. Use 5.1/home-theater settings in games. Windows volume and mute control listening volume.

The driver's **CABLE In 16ch** name describes its capacity. SurroundForge configures it to **six channels at 48 kHz**, with assigned FL/FR/FC/LFE/BL/BR speakers. Startup repairs the speaker mask if Windows loses it after reboot.

**Stop SurroundForge** restores the previous Windows output defaults. The launcher identifies its own encoder by executable path, PID and start time, and preserves a separately selected communications headset.

## Source map

| Location | Purpose |
|---|---|
| `surround/Bridge.ps1` | Start/stop, startup, speaker-layout repair and diagnostics |
| `surround/Setup.ps1` | Destination-PC device selection and vendor setup |
| `surround/source/engine` | Native capture, volume/mute, AC3 and optical transport |
| `surround/tests` | Native, lifecycle, layout and live integration regressions |
| `surround/installer` | WiX MSI builder, installer validation and notices |
| `docs/BUILD.md` | Rebuilding and validating the software |
| `docs/TROUBLESHOOTING.md` | Diagnosing stereo, silence and reboot problems |
| `changelog.md` | Release history |

## What is deliberately local

Device IDs, running process state, audio/event logs, registry backups, downloaded drivers, FFmpeg binaries, build output and installers stay outside Git. The original diagnostic history is preserved on this computer. Diagnostics record signal peaks, not audio recordings.

The repository is local and has not been published. The working installation stays in its current folder so its startup shortcut and live encoder continue to work.

## Credits and licenses

The engine is adapted from [strepto42/virtual-ac3-encoder](https://github.com/strepto42/virtual-ac3-encoder), upstream v0.1.5, commit `3be5ba878f9689b0257c03ff4759d19cdf552cb5`. Its original MIT license and notices are retained in `surround/source/`. FFmpeg, doctest, VB-Audio, C-Media and Microsoft runtime components retain their respective licenses; see `surround/installer/Third Party Notices.txt`.

The repository contains the reusable source and instructions. Vendor installer binaries remain local, and the MSI was built as a personal migration package. Other hardware combinations have not been independently verified.
