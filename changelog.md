## v0.1.6-local — 2026-10-09 01:31:47

- True5.1 PC audio via six-channel virtual Windows input, AC3 encoding and existing C-Media optical adapter.
- C-Media legacyAC3 initialization fallback; isolated speaker tests and capture-format guard.
- Start/stop controls, saved prior defaults and sign-in startup.
- User verified six discrete speakers through full route; native format/channel/controller regressions pass.

## v0.1.7-local — 2026-10-09 01:49:19

- Windows system volume and mute now control all six PCM channels before AC3 encoding.
- Live mute regression failed before and passes after; native dB/six-channel and controller guards pass.
- User confirmed audible volume changes and mute through Samsung.


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
