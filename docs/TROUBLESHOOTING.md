# Troubleshooting

## Windows says two channels on optical output

The physical S/PDIF endpoint's two-channel carrier setting does not describe the game's decoded AC3 channel count. Games should output to the configured **CABLE In 16ch** virtual input, which SurroundForge configures to six assigned channels. The bridge encodes those channels for the receiver.

## Surround disappears after reboot

This setup once retained six channels but lost the speaker assignments (`mask=0x0`). DirectSound then reported unassigned `DIRECTOUT`, although test tones could still reach six speakers. The v0.1.9 launcher verifies and restores `mask=0x3f` before starting. Channel count alone is insufficient.

Start the bridge before opening the game. Use the game's speaker/home-theater settings and disable headphone/binaural modes where appropriate. Restart a game that was already open when the Windows output configuration changed.

## Silence or wrong output

Check the receiver's optical input selection, optical OUT on the USB adapter, **SPDIF Out** in C-Media/Xear settings, and the physical output selected in Setup. The encoded optical endpoint is opened exclusively by the bridge. Stop another player that is using that same optical output directly, and use the virtual input for ordinary PC/game audio.

## See what a game actually produces

The bridge writes `surround/channel-activity.csv`, with timestamped raw FL/FR/FC/LFE/BL/BR peaks every five seconds. It stores no audio recording. Current and previous CSV files are limited to approximately 2 MiB each. These peaks are measured **before** Windows volume/mute, so a muted output can still show source activity.

Menu music and startup videos can be stereo even when racing audio is surround. A quiet center or subwoofer in a particular scene does not prove a fault. Compare a race's time and source activity with the speaker test rather than counting every active speaker on every frame.

```powershell
& .\surround\Bridge.ps1 -Action Status
& .\surround\Bridge.ps1 -Action Diagnostics
```

Diagnostics preserves endpoint format, defaults, volume/mute, audio sessions, bridge logs, channel history and recent relevant Windows events in a timestamped local folder. Open `.evtx` exports with **Event Viewer → Action → Open Saved Log**. Disabled event channels are not enabled; missing/unavailable channels are reported in the snapshot.

Private device IDs and event data belong to the computer that produced them. Share a reviewed/redacted bundle only when needed. The original local investigation and rollback settings remain in the ignored diagnostic folders.
