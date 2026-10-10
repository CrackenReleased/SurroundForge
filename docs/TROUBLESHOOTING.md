# Troubleshooting

## Windows says two channels on optical output

The physical S/PDIF endpoint's two-channel carrier setting does not describe the game's decoded AC3 channel count. Games should output to the configured **SurroundForge 5.1** / **CABLE In 16ch** virtual input, which SurroundForge configures to six assigned channels. The bridge encodes those channels for the receiver.

## Surround disappears after reboot

This setup once retained six channels but lost the speaker assignments (`mask=0x0`). DirectSound then reported unassigned `DIRECTOUT`, although test tones could still reach six speakers. The v0.1.9 launcher verifies and restores `mask=0x3f` before starting. Channel count alone is insufficient.

Start the bridge before opening the game. Use the game's speaker/home-theater settings and disable headphone/binaural modes where appropriate. Restart a game that was already open when the Windows output configuration changed.

## Silence or wrong output

Check the receiver's optical input selection, optical OUT on the USB adapter, **SPDIF Out** in C-Media/Xear settings, and the physical output selected in Setup. The encoded optical endpoint is opened exclusively by the bridge. Stop another player that is using that same optical output directly, and use the virtual input for ordinary PC/game audio.

If `Bridge.ps1 -Action Status` says `Running=False` while Windows still uses the virtual input, save diagnostics and run `Bridge.ps1 -Action Start`. Reloading a browser page cannot start the native encoder. The v0.1.13-local bridge starts an owned supervisor; Status reports `Supervised` and the native health snapshot. Stop cancels recovery before stopping the encoder and restoring defaults. DisableStartup removes this installation's sign-in shortcut and disables recovery while current audio continues.

## Jitter after prolonged playback

The v0.1.12-local runtime fixes a reproduced PCM queue overflow defect: a full power-of-two byte queue could publish part of a six-channel frame, shifting later samples between channels. Overflow now rejects the whole incoming packet and preserves queued data. The native `test_ringbuffer.cpp` regression forces repeated overflow and verifies unchanged channel order after recovery. An isolated dropped packet may still produce a brief dropout; this change prevents persistent sample misalignment. The reported overnight incident had no overflow counter, so it cannot establish that this was its only cause.

The later post-reboot/tab-switch recurrence exposed a different fault: v0.1.14's exclusive USB event loop submitted about 28.55 bursts/second (43,850 carrier frames/second), below the 31.25 bursts/second required for 48 kHz. The encoder used under 1% of one CPU core; its heartbeat continued while the queue's drift trimming discarded the excess input. A responsive process was not evidence of correct audio timing.

v0.1.15 uses a local 4 ms high-resolution timer and `GetCurrentPadding` to refill actual free device space with complete AC3 bursts. It requests three bursts of headroom; this adapter supplies a 4,800-frame/100 ms capacity. Delayed wakes can refill several bursts, fractional free space waits for a complete burst, and unused capacity never inserts carrier zeros. The source remains six assigned 48 kHz channels with gain/mute applied before encoding. This follows the [exclusive non-event padding contract](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-getcurrentpadding).

Use `test_bridge_recovery_live.ps1 -Run -CadenceOnly -ObservationSeconds 240` while playing media and switching tabs. `submittedFrames` divided by elapsed heartbeat time measures carrier delivery; `renderCycles` now counts variable-sized submissions and must not be multiplied by a fixed buffer size. `capturedFrames`, `trimmedFrames` and `captureDiscontinuities` distinguish source timing, deliberate drift correction and Windows capture loss from rejected queue packets. One capture discontinuity at initialization and a few initial silent bursts are normal; sustained changes during playback need investigation. These counters extend the same fixed-size overwritten snapshot and contain no audio.

## Failure handling in the current runtime

| Failure or normal condition | Handling | Verification |
| --- | --- | --- |
| Full PCM queue | Reject a complete packet; preserve channel alignment; count dropped packets | Native overflow and channel-order regressions |
| Capture/render device API failure | Record the failed operation and HRESULT; stop/join workers; exit nonzero | Fake COM clients exercise actual worker paths |
| Missing optical events | Three consecutive two-second timeouts become a failure; one recovered timeout is tolerated | Native timeout regression |
| Exited or unresponsive encoder | Supervisor checks exact process ownership and a progress-based heartbeat; restart with increasing delay capped at 60 seconds | Mock supervisor regressions and explicit live recovery test |
| Repeated crashes or disconnected/busy device | Retry with backoff; reset the failure count only after sustained healthy operation | Mock repeated-death and failed-launch regressions |
| First device start fails after sign-in | Save startup intent and original defaults, then retry; preserve outputs changed while waiting. If Windows cannot supply original defaults, fail closed and Start again when Windows Audio is ready | Delayed-start role and intent regressions |
| New bridge script with old native encoder | Current launcher requires native v0.1.15 or newer before supervision; prevent old callback pacing, missing-heartbeat restart loops and old publication behavior | Runtime compatibility regression |
| Temporary health-file sharing conflict | v0.1.14 readers permit atomic replacement. Native publication retries for up to ten seconds while audio continues; persistent failure still triggers recovery | Real file-lock regression fails v0.1.13, passes v0.1.14 with identical encoder PID/settings; native deadline/reset and actual open-reader replacement tests |
| Hung control query or diagnostic monitor | Kill only the directly launched child after a bounded timeout; diagnostics does not hold the lifecycle mutex | Native-command timeout regression |
| Intentional Stop, stale watcher, reused PID, another installation | Cancel the watcher generation first; never terminate or relaunch an unowned process | Ownership/generation tests and live Stop test |
| User changes playback output or communications headset | Recovery preserves those choices and original rollback targets | Mock role-preservation regression; live defaults comparison |
| Source silence, paused media, Windows mute | Healthy workers keep heartbeating; source peaks do not decide liveness | Native silent/empty capture and supervisor regressions |
| Volume API unavailable | Emit silence immediately; sustained failure escalates after six seconds | Native volume-read regression |
| NaN/infinite PCM or invalid gain | Replace affected samples with silence without shifting channels | Native PCM regression |
| Invalid encoder setup, truncated burst, failed muxer write | Reject invalid inputs and incomplete output; propagate failure | Encoder regressions and six-channel encode/decode test |
| Delayed USB callbacks or refill wake | Timer-driven refill follows actual free space and catches up with several complete bursts; progress counts successful submissions only | Production refill tests, variable padding and sustained live cadence regression |
| Optical capacity not divisible into complete AC3 bursts | Require at least two bursts of headroom; fill only complete bursts and leave fractional capacity unused without inserting zeros | Fake 4,608/5,000-frame endpoints exercise real encoder/refill and inspect every burst preamble |
| Transient optical buffer unavailable | Retry on next timer wake without consuming PCM or releasing an unacquired buffer; sustained lack of progress still reaches watchdog | Production refill acquisition-failure and full-padding regressions |
| Corrupt ownership/configuration state | Retain evidence and fail closed instead of guessing which process/device to control | Supervisor saved-state regressions |

`engine-health.json` is one overwritten local snapshot, not an audio recording. It reports worker progress, packet drops, underruns, render timeouts, status and the last symbolic error. A source pause can legitimately increase underruns while encoded silence keeps the optical link active. The main loop publishes healthy updates only when both workers progress; a blocked worker cannot be certified by a responsive main thread. The supervisor allows bounded startup grace and detects a heartbeat older than 15 seconds. Its current and previous logs are limited to approximately 64 KiB each; failed/stale state is retained until replaced or explicitly repaired.

Software cannot reconnect an optical cable, turn on a receiver, recover a frozen operating system or infer a newly assigned device ID safely. If device IDs change, select the devices in Setup. Physical unplug/replug, actual sleep/resume and overnight duration still require hardware observation. The original unexplained process exit remains unproven; the new diagnostics and supervisor address future detection/recovery without claiming its cause.

Windows documents device invalidation and empty/silent capture conditions in [IAudioCaptureClient::GetBuffer](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer), and output release failures in [IAudioRenderClient::ReleaseBuffer](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiorenderclient-releasebuffer). Those conditions are handled according to their meaning: an empty packet is valid; a failed device operation cannot establish a healthy stream.

## See what a game actually produces

The bridge writes `surround/channel-activity.csv`, with timestamped raw FL/FR/FC/LFE/BL/BR peaks every five seconds. It stores no audio recording. Current and previous CSV files are limited to approximately 2 MiB each. These peaks are measured **before** Windows volume/mute, so a muted output can still show source activity.

Menu music and startup videos can be stereo even when racing audio is surround. A quiet center or subwoofer in a particular scene does not prove a fault. Compare a race's time and source activity with the speaker test rather than counting every active speaker on every frame.

```powershell
& .\surround\Bridge.ps1 -Action Status
& .\surround\Bridge.ps1 -Action Diagnostics
```

Diagnostics preserves endpoint format, defaults, volume/mute, audio sessions, bridge/health/supervisor state and logs, channel history and recent relevant Windows events in a timestamped local folder. Open `.evtx` exports with **Event Viewer → Action → Open Saved Log**. Disabled event channels are not enabled; missing/unavailable channels are reported in the snapshot.

Private device IDs and event data belong to the computer that produced them. Share a reviewed/redacted bundle only when needed. The original local investigation and rollback settings remain in the ignored diagnostic folders.

## Directory migration and custom driver identity

The canonical checkout on this machine is `E:\SurroundForge`. If builds fail with an `audio-diagnostics` path, configure a fresh CMake build as described in [BUILD.md](BUILD.md#canonical-directory-and-moved-builds). Generated build caches retain absolute paths after a directory move; source scripts resolve paths relative to their own location.

`SurroundForge 5.1 (VB-Audio Virtual Cable)` is the branded verified vendor endpoint. `SurroundForge 5.1 (SurroundForge Audio)` is the endpoint advertised by the custom WaveRT source. Branding a VB-CABLE endpoint does not install the custom driver. No native-driver package has been built or verified here; see [driver status](../surround/source/driver/README.md).

Inspect `SurroundForge.lnk` in the Windows Startup folder if sign-in launch fails after a move. Its arguments and working directory should point to the installation that owns the bridge. Re-enable startup deliberately from that installation; do not guess new process ownership from stale state.