## v0.1.17-local — 2026-10-21 — Dynamic 4-color status emblem, desktop restart shortcut, and MSI installer shortcut delivery

- **Dynamic 4-Color Status Palette**: Configured the Sonic Anvil emblem, GUI window icon, and system tray icon in `surround/Tray.ps1` to reactively reflect engine health state: Teal (`#00E4C4`) for Running/Good, Orange (`#FAA00A`) for Issues (Recovering/Starting/Needs attention), Gray (`#8291A5`) for Stopped (manual pause), and Red (`#F8414B`) for Off (offline/snapshot error).
- **Desktop Restart Shortcut**: Added `Ensure-SetupDesktopShortcut` to create/maintain `Start SoundForge.lnk` on the user's Desktop (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File "...\Bridge.ps1" -Action Start`, minimized style 7, canonical `surroundforge.ico`). Integrated into `Save-SetupConfiguration` in `Setup.ps1`.
- **Installer Integration**: Added `DesktopFolder` directory reference and `DesktopStartShortcut` component to the WiX MSI manifest in `surround/installer/Build-Msi.ps1` and included `Tray.ps1` in the MSI payload; verified via `surround/installer/Test-Msi.ps1`.
- **Offline Suite & Regression Coverage**: Added desktop shortcut assertions to `surround/tests/test_setup.ps1`, 4-color palette assertions to `surround/tests/test_tray.ps1`, and adapted `surround/tests/test_bridge_control.py` for headless/offline optical checks (16/16 test suites passing in `Run-Tests.ps1 -Suite Offline`).

## v0.1.16-local — 2026-10-10 — migration revision 1

- Establish `E:\SurroundForge` as the canonical checkout and GitHub source repository; update root/source/driver build, troubleshooting, signing and attribution docs. AI Hub project files are documentation mirrors.
- Distinguish the live v0.1.15 vendor-driver route, v0.1.16 controls/source and v0.1.11 MSI tooling from the unbuilt native WaveRT driver source. Microsoft attestation signing does not imply HLK/WHQL certification.
- Fail the driver builder when the WDK is missing and reject unsupported `-Sign`; prefer amd64 MSBuild. The regression reproduces the prior silent success.
- Test fresh builds with `Run-Tests.ps1 -EngineBuildDirectory` after relocation; keep running binaries intact. Offline controller guards no longer initialize real C-Media hardware.
- Fix the suite summary so exactly one failing test exits nonzero; add executable child-process regressions for one/multiple failures and a single pass.
- Include canonical source guidance and exclude all WDK platform outputs/CABs; keep private state, vendor media and legacy upstream test-install helpers local.

## v0.1.16-local — 2026-10-10 — SurroundForge 5.1 endpoint branding, Sonic Anvil controller & 8-speaker calibration stage, WaveRT kernel driver source & attestation packaging tooling

- Brand the active 5.1 virtual audio endpoint as `SurroundForge 5.1` (`PKEY_Device_DeviceDesc`) in `bridge_control.exe` (`--set-51` and `--set-mix-51`) and persist `PKEY_AudioEndpoint_PhysicalSpeakers = 0x3f` after `SetDeviceFormat` so Windows Sound Output displays `SurroundForge 5.1` and games receive true 5.1 surround (`layout_51=1`).
- Replace the placeholder `"S"` circle in `Tray.ps1` and `IDI_APPLICATION` in `TrayApp.cpp` with the custom **Sonic Anvil** vector icon (`SurroundForgeTrayIcon::RenderSonicAnvilBitmap` / `WriteSonicAnvilIco`), compile and launch a native GUI host (`$env:LOCALAPPDATA\SurroundForge\SurroundForge.exe`) with the embedded multi-size Sonic Anvil `.ico` resource onto `WinSta0\Default` so the Windows 11 Taskbar button displays the Sonic Anvil logo instead of the PowerShell icon, and add a **Stop audio & close** button (`UseMnemonic = $false`) and context-menu action.
- Add an interactive 8-speaker spatial calibration stage (`FL`, `FC`, `FR`, `LFE`, `SL`, `SR`, `BL`, `BR`) and `Stereo` / `5.1` / `7.1` layout switcher to `Tray.ps1` backed by `bridge_control.exe --tone-speaker ID SPEAKER LAYOUT` (synthesizing distinct G3-series harmonic tones per speaker over shared-mode WASAPI without interrupting the optical bridge).
- Update `IsCableInput` (`BridgeControl.cpp`) and `Test-SetupMultichannelInput` / `Test-SetupVirtualOutput` (`Setup.ps1`) to accept both `CABLE In 16ch (VB-Audio Virtual Cable)` and `SurroundForge 5.1 (...)` endpoints while continuing to block virtual endpoints from being chosen as physical optical outputs.
- Upgrade the in-tree WaveRT kernel driver (`surround/source/driver`) to `Cracken Released, LLC` / `SurroundForge 5.1` (`ROOT\SurroundForgeAudio`), fix `SpeakerJackDescBridge` in `speakertoptable.h` from `KSAUDIO_SPEAKER_STEREO` to `KSAUDIO_SPEAKER_5POINT1`, persist `PKEY_AudioEndpoint_PhysicalSpeakers = 0x0000003f` in `SimpleAudioSample.inx`, and add 32-bit IEEE float + 32-bit PCM 6-channel 48 kHz format support in `speakerwavtable.h`.
- Add `surround/source/driver/New-AttestationCab.ps1` and document the Microsoft Partner Center Hardware Program + certificate association/submission workflow in `docs/SIGNING.md`.

## v0.1.15-local — 2026-10-10 — optical delivery follows device space

- Replace exclusive USB callback pacing with timer-driven, padding-aware refill. Live v0.1.14 delivery was approximately 43,850 frames/second despite a ready heartbeat; the repaired route delivers approximately 48,000.
- Request three AC3 bursts of output headroom (100 ms capacity on this adapter), catch up after delayed wakes, preserve whole bursts across fractional device capacity, and never stuff unused carrier space.
- Count captured/submitted/trimmed frames and capture discontinuities in the existing overwritten health snapshot; no audio recording or new diagnostic dataset.
- Refill regressions fail the old code and pass the repair. Native suite: 39 cases/1,018 assertions; supervisor compatibility, lifecycle and startup-ownership tests pass. Added sustained live cadence observation; user confirmed clear and steady audio while testing the repaired route.
- Local runtime only; release tooling/development MSI remain v0.1.11. Overnight, full reboot and physical reconnect coverage remain unverified for this version.

## v0.1.14-local — 2026-10-10 — health-file contention without audio interruption

- Fix a v0.1.13 regression: a temporary health-snapshot replacement failure terminated otherwise healthy audio and caused supervisor restarts.
- Allow replacement while watcher/Status reads the snapshot; tolerate transient publication failure while audio continues, bounded to ten seconds before recovery.
- Live file-lock regression fails v0.1.13 and passes v0.1.14 with unchanged encoder identity/defaults/volume/mute. Actual open-reader replacement and native deadline/reset regressions pass; 35 native cases/823 assertions pass.
- Prior lifecycle, speaker-layout and runtime compatibility regressions pass. Real crash recovery and intentional Stop still pass. Same encoder remained active beyond two minutes with source audio and no new restarts; user confirmed sound is steady.
- Local runtime only; no new MSI/publication. Original overnight incident cause and physical sleep/reconnect/overnight coverage remain unproven.

## v0.1.13-local — 2026-10-10 — audio runtime and recovery

- Detect failed or stalled capture/render workers and publish progress-based health; restart only this installation's owned encoder with bounded backoff.
- Preserve manual output choices, volume/mute and rollback targets; serialize lifecycle actions and cancel recovery on Stop.
- Bound native control calls, reject older incompatible runtimes, and retry initial device startup when original defaults can be safely saved.
- Reject incomplete encoded bursts and unsupported optical buffer geometry; silence invalid PCM and sustained unreadable volume safely.
- Native suite passes 34 cases/813 assertions. Supervisor/lifecycle regressions and real encoder-exit recovery, idempotent Start and intentional Stop pass; six-channel encode/decode passes.
- Final runtime is active locally; no new MSI or source publication. Latest development MSI remains v0.1.11. Physical sleep/resume, USB reconnect and overnight observation remain unverified.

## v0.1.12-local — 2026-10-10 — audio runtime only

- Preserve complete PCM packets when the queue overflows; prevent lasting six-channel sample misalignment after a stall.
- Add executable overflow/channel-order regressions that fail the old byte clamp and pass the repaired queue; all 22 native tests pass.
- Restarted the stopped local bridge; user confirmed clear sound after the initial recovery. Updated runtime initialized six assigned channels and encoded optical output with live source audio measured.
- Why the previous process exited remains unproven; no automatic restart supervisor or new MSI is included. Release tooling/latest development MSI remains v0.1.11. Overnight stability is unverified.

## v0.1.6-local — 2026-10-09 01:31:47

- True5.1 PC audio via six-channel virtual Windows input, AC3 encoding and existing C-Media optical adapter.
- C-Media legacyAC3 initialization fallback; isolated speaker tests and capture-format guard.
- Start/stop controls, saved prior defaults and sign-in startup.
- User verified six discrete speakers through full route; native format/channel/controller regressions pass.

## v0.1.7-local — 2026-10-09 01:49:19

- Windows system volume and mute now control all six PCM channels before AC3 encoding.
- Live mute regression failed before and passes after; native dB/six-channel and controller guards pass.
- User confirmed audible volume changes and mute through the connected receiver.


## v0.1.8 — 2026-10-09 02:14:10
- Portable x64 MSI with destination-device setup, complete vendor media, native runtime, volume/mute and safe uninstall.
- MSI extraction and actual install/uninstall tests pass; existing laptop defaults/startup preserved.


## v0.1.9 — 2026-10-09 07:51:16
- Restore missing 5.1 speaker assignments at startup; reject unassigned gaming capture.
- Add bounded per-channel history, audio-session diagnostics and Event Viewer exports.
- Native failure/repair reproducer and six-channel monitor pass; NFS startup rear audio measured. Actual races/next reboot pending.
- Updated MSI extraction and actual install/uninstall pass.

### SurroundForge source repository — v0.1.9 documentation revision 1

- User confirmed game surround working after the speaker-layout repair.
- Created a clean local source repository with build/setup/troubleshooting documentation and upstream attribution.
- Kept machine-specific state, event logs, vendor binaries and installer artifacts outside version control; preserved their existing local copies.
- Live integration tests now read this computer's configured devices. Added a repository hygiene regression.

## v0.1.10 — 2026-10-09

- Name the product, setup, MSI, install folder, Start menu and startup shortcut SurroundForge. Describe real-time 5.1 enabled through a USB optical adapter, independent of receiver brand.
- Preserve the MSI upgrade identity; migrate earlier owned startup names without duplicate launches or changes to other installations.
- Add receiver-neutral identity and startup ownership regressions, packaged native-version checks, upgrade validation, and an offscreen setup preview.
- Support a separate package build so the working audio engine can remain running during games. Retain dependency licenses and attribution.
- Remember custom installation folders so normal removal can find and stop the correct installed bridge; pin this with an actual install/uninstall regression.
- Jitter evidence captured before a bridge-only reset; user confirmed stable audio afterward. Cause remains unproven. No audio processing algorithm changed in this release.

## v0.1.11 — 2026-10-09 — release tooling, signing identity pending

- Require company Authenticode signing, SHA256/RFC3161 timestamps and publisher/root verification before release MSI publication. Support approved certificate-store and Microsoft Artifact Signing providers without enrolling accounts or creating keys.
- Keep explicit unsigned development installers outside dist. Validate signed MSI/payloads before installer tests execute them. Preserve original Microsoft/vendor signatures and stage application signing away from the running engine.
- Use Cracken Released, LLC in MSI manufacturer metadata. Add signing regressions, key/config exclusions and official-source documentation distinguishing free Store/SignPath routes from standalone company MSI signing.
- Correct the earlier description of C-Media setup.exe: its wrapper is unsigned, distinct from signed driver catalogs. Public builds reject it; original media and the working audio installation are preserved.
- No public signed installer exists yet. Audio runtime remains v0.1.10; no capture, encoding, device or live-process changes.
