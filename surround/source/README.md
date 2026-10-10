# SurroundForge source

The canonical project is `E:\SurroundForge` on this machine. See the [root README](../../README.md), [build guide](../../docs/BUILD.md) and [notices](NOTICE.md).

- `engine/`: C++17 WASAPI capture, Windows gain/mute, AC3 encoding and timer/padding-driven optical transport.
- `driver/`: Microsoft SimpleAudioSample-derived render-only WaveRT virtual 5.1 source; WDK build, Microsoft signing and native-driver integration are outstanding.
- `scripts/`: reusable FFmpeg fetch and test-WAV generation helpers. Private upstream deployment scripts are not a supported SurroundForge installer.

Source revision: v0.1.16-local, migration revision 1. The live engine remains v0.1.15-local and MSI tooling remains v0.1.11. Builds and vendor dependencies are local generated inputs, excluded from Git.