# SurroundForge WaveRT virtual 5.1 driver

Source revision **v0.1.16-local, migration revision 1**. This is a SurroundForge adaptation of Microsoft's MIT SimpleAudioSample, retained from the upstream virtual-ac3-encoder project. Preserve Microsoft copyright headers; see `../NOTICE.md` and `../LICENSE`.

The driver is a render-only virtual audio endpoint, not the AC3 encoder or USB hardware driver. It advertises six assigned FL/FR/FC/LFE/BL/BR channels at 48 kHz, PCM16/PCM32/float32, `KSAUDIO_SPEAKER_5POINT1` and an INF physical-speaker mask of `0x3f`. The canonical hardware ID is `ROOT\SurroundForgeAudio`; `ROOT\SimpleAudioSample` remains in the INF for legacy compatibility. The endpoint is named **SurroundForge 5.1 (SurroundForge Audio)**. Microphone sample source remains for provenance, but capture endpoint registration is disabled.

The userspace engine captures the render endpoint using WASAPI loopback, applies Windows gain/mute, encodes AC3 and delivers IEC 61937 bursts to the physical optical output. The driver never loads FFmpeg into the kernel.

## Build

From the repository root (`E:\SurroundForge` on the development machine):

```powershell
& .\surround\source\driver\Build-Driver.ps1 -Configuration Release -Platform x64
```

Install Visual Studio 2022 C++ tooling and a compatible WDK with the `WindowsKernelModeDriver10.0` toolset first. The builder uses amd64 MSBuild and fails when required tooling is absent. It does not provide publisher signing; `-Sign` is rejected explicitly. Expected output is `x64/Release/package/` containing `SimpleAudioSample.sys`, `.inf` and `.cat`. These files and generated `x64/ARM64` trees are excluded from Git.

The WDK is absent on the current machine, so compilation and hardware behavior are unverified. Advertising formats in source does not prove successful Windows negotiation or game playback.

## Signing and installation gates

```powershell
& .\surround\source\driver\New-AttestationCab.ps1 -VerifySourceOnly
# Requires an actual built package:
& .\surround\source\driver\New-AttestationCab.ps1
```

The CAB helper validates source metadata and packages build output; it neither signs nor submits it. Microsoft attestation signing and HLK/WHQL certification are distinct routes. See [the signing guide](../../../docs/SIGNING.md) for official requirements and the current status.

No public native-driver package or automatic native-driver installation exists. Setup recognizes its endpoint name, but the existing MSI still bundles the VB-CABLE route. Legacy private upstream test-install/uninstall helpers are not supported deployment instructions. Do not disable Secure Boot, enable test signing or import a test certificate as part of normal user setup. Driver compilation, Microsoft signing, installation integration, loopback/channel validation and hardware playback are remaining release gates.