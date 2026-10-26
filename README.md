# SurroundForge

**Forge real PC surround sound through a USB optical adapter.**

## Windows installer

**[Find the Windows installer on GitHub Releases](https://github.com/CrackenReleased/SurroundForge/releases).** No public MSI is available yet. The complete v0.1.21 development MSI is built and checked locally, but it is unsigned and is not a public download. A release will appear at that link after publisher signing and bundled driver redistribution are cleared. See [release requirements](docs/SIGNING.md).

Source revision: **v0.1.21-local package**. The native engine is **v0.1.16-local**; controls are **v0.1.20-local**. No signed public installer or native-driver release has been produced.

Canonical local checkout: `E:\SurroundForge`. Public source: [CrackenReleased/SurroundForge](https://github.com/CrackenReleased/SurroundForge). Commands below run from the repository root; other computers may clone into any directory.

```text
Game / Windows audio
    → virtual six-channel 48 kHz render endpoint
    → WASAPI loopback + Windows volume/mute
    → user-mode AC3 encoder
    → optical S/PDIF → compatible receiver → 5.1 speakers
```

The verified local route uses the signed VB-CABLE virtual endpoint and the USB adapter's optical output. The endpoint may display as **SurroundForge 5.1 (VB-Audio Virtual Cable)** after branding; that name does not mean the custom kernel driver is installed. The receiver must decode AC3 (Dolby Digital) over optical, and the adapter must support encoded S/PDIF output. Ordinary stereo sources remain stereo; game surround does not rely on stereo upmixing. Other hardware combinations and overnight stability remain unverified.

## Native driver status

`surround/source/driver/` contains SurroundForge's Microsoft SimpleAudioSample-derived WaveRT driver source, with a render-only **SurroundForge 5.1 (SurroundForge Audio)** endpoint, `ROOT\SurroundForgeAudio` identity, six speakers at 48 kHz, PCM16/PCM32/float32 formats and a persistent `0x3f` speaker mask. The user-mode engine still performs capture, encoding and optical transport.

The WDK is not installed on the current development machine, and no compiled `.sys/.inf/.cat` package or native-driver hardware verification is available. Setup recognizes the native endpoint name, but the MSI and vendor installation flow still use VB-CABLE. Native driver distribution requires a successful WDK build, Microsoft signing and integration validation. [Driver build notes](surround/source/driver/README.md) and [signing requirements](docs/SIGNING.md) describe these remaining gates.

## Install and use the verified route

The private v0.1.10 migration MSI and v0.1.21 development MSI are unsigned local artifacts, excluded from Git. Public MSI creation requires verified publisher signing and distributable vendor media.

1. On Windows x64, open **SurroundForge Setup** from the existing installation or run `surround/Setup.ps1` from a checkout with built dependencies.
2. Connect the adapter's optical OUT to the receiver's optical IN and select that input.
3. Install missing vendor drivers using Setup; restart if requested. Enable **SPDIF Out** in the adapter's C-Media/Xear settings.
4. Select the virtual input and physical optical output, then **Save and start surround**. Enable startup if desired.
5. Use 5.1/home-theater settings in games. Windows volume and mute control listening volume.

Startup checks six assigned FL/FR/FC/LFE/BL/BR speakers at 48 kHz and repairs a missing speaker mask. The configured virtual playback endpoint appears in Windows Sound Output while audio runs and is hidden after Stop or a failed startup. The unused stereo **CABLE Input** endpoint stays hidden. **Stop SurroundForge** cancels supervision and restores the previous Windows output defaults. Closing the controller window with X stops audio; **Hide controller (audio continues)** in the tray menu leaves it running.

The Sonic Anvil controller provides speaker calibration and Stereo/5.1/7.1 test layouts. The custom kernel endpoint and AC3 optical transport are 5.1; an eight-speaker calibration UI does not establish a native 7.1 optical transport.

## Source map

| Location | Purpose |
|---|---|
| `surround/Bridge.ps1` | Owned engine lifecycle, supervision, startup and diagnostics |
| `surround/Setup.ps1` | Destination-PC device selection and vendor setup |
| `surround/Tray.ps1` | Sonic Anvil controller and speaker calibration |
| `surround/source/engine` | Native capture, volume/mute, AC3 and optical transport |
| `surround/source/driver` | Custom WaveRT virtual 5.1 driver source and build/CAB tooling |
| `surround/tests` | Native, mock, configuration and integration regressions |
| `surround/installer` | WiX MSI builder, signing safeguards and notices |
| `docs/BUILD.md` | Rebuilding, testing and directory migration |
| `docs/TROUBLESHOOTING.md` | Audio and relocation diagnostics |
| `docs/SIGNING.md` | Application and driver signing status |
| `changelog.md` | Release and documentation history |

Run the existing offline checks with `powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Tests.ps1 -Suite Offline` after building the engine. CI builds and tests source on Windows; it does not compile the kernel driver or certify hardware playback.

## Local files and provenance

Device IDs, ownership/health state, logs, registry backups, downloaded vendor media, FFmpeg binaries, build outputs and installers stay outside Git. Diagnostics store signal peaks rather than audio recordings. The project-scoped private continuity files are `INSTALLATION.md` and `what_and_how_log.md`; the AI Hub documentation directory is a read-only mirror of this checkout.

The engine is adapted from [strepto42/virtual-ac3-encoder](https://github.com/strepto42/virtual-ac3-encoder), upstream v0.1.5, commit `3be5ba878f9689b0257c03ff4759d19cdf552cb5`. Its MIT license and Microsoft's driver copyright headers are retained. See [source notices](surround/source/NOTICE.md) and `surround/installer/Third Party Notices.txt` for dependency attribution. Vendor installer binaries are local inputs, not public repository deliverables.
