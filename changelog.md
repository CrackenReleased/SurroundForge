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
