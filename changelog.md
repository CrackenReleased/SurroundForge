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
