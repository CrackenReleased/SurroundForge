# Build and verify SurroundForge runtime v0.1.15-local

The local audio runtime is v0.1.15-local; release tooling and the latest development MSI remain v0.1.11. The runtime adds device-space-driven optical refill, frame delivery counters, worker failure handling, an owned recovery supervisor, packet integrity checks and bounded health diagnostics. No new MSI was built for this local runtime update. [Signing setup and free distribution options](SIGNING.md) describe the outstanding identity/vendor requirements. Public MSI creation requires verified company signing; examples below explicitly build development packages.

The working audio installation is Windows x64. The native engine uses C++17, Visual Studio 2022 Build Tools with a Windows SDK, CMake, and dynamically linked FFmpeg libraries. Python 3 is used for several integration tests. WiX 3.14 is used to build the MSI. There is no new kernel driver to compile or sign.

From the repository root, obtain the FFmpeg development files using the existing script:

```powershell
& .\surround\source\scripts\fetch-ffmpeg.ps1 -Prefer master
cmake -S surround/source/engine -B surround/source/engine/build -G "Visual Studio 17 2022" -A x64 "-DVAC3_VERSION=0.1.15-local"
cmake --build surround/source/engine/build --config Release
ctest --test-dir surround/source/engine/build -C Release --output-on-failure
```

The download is a rolling LGPL shared build. The original working build's version and provenance are recorded in `surround/installer/FFmpeg-Version.txt`; a later download is not an exact reproduction of that dependency. Do not download over the DLLs of a running encoder: stop the owned bridge first.

Some PowerShell build/test helpers locate Visual Studio Build Tools' bundled CMake at its normal installed path. If your installation differs, adapt that path or provide CMake on PATH. This repository has not been tested as a clean build on another computer.

## Tests

Run the comprehensive offline test suite (all native, mock & regression tests):

`powershell
& .\Run-Tests.ps1 -Suite Offline
`

Or individual safe test scripts:

```powershell
& .\surround\tests\test_startup_speaker_layout.ps1
& .\surround\tests\test_bridge_lifecycle.ps1
& .\surround\tests\test_bridge_supervisor.ps1
& .\surround\tests\test_bridge_portable.ps1
& .\surround\tests\test_setup.ps1
& .\surround\tests\test_product_identity.ps1
& .\surround\tests\test_release_signing.ps1
& .\surround\tests\test_startup_identity.ps1
& .\surround\tests\test_setup_render.ps1
& .\surround\tests\test_speaker_layout.ps1
& .\surround\tests\test_repository_hygiene.ps1
```

After Setup has configured the local devices, `test_bridge_control.py` checks controller guards using the selected devices. `test_channel_roundtrip.py` generates the reusable fixture and verifies encoded/decode channel isolation; it requires FFmpeg's CLI as well as the compiled native encoder. `test_channel_monitor.py` and `test_endpoint_volume.py` exercise live loopback and temporarily change volume/mute, restoring them afterward. Read their docstrings and use them only during an intentional test session.

`test_bridge_recovery_live.ps1 -Run` is an explicit integration test: it terminates only the configured owned encoder, waits for automatic recovery, checks defaults/volume/mute and repeated Start, then verifies intentional Stop and restores the running route in `finally`. It briefly interrupts audio. Begin with the updated native runtime and supervised bridge running; do not run it during a game or call.

`test_bridge_recovery_live.ps1 -Run -HealthContentionOnly` holds the health file open without delete sharing across multiple heartbeat periods. It asserts that the same encoder and settings survive and publication resumes afterward. It failed v0.1.13 and passes v0.1.14. Both modes restore the running route if a regression stops it.

`test_bridge_recovery_live.ps1 -Run -CadenceOnly -ObservationSeconds 240` observes the current engine while media plays and tabs switch. It checks sustained 48 kHz carrier delivery from submitted frame counts, no capture queue drops, no restarts and fresh health. This mode never changes settings or restarts the bridge, and permits user volume/mute changes while listening. Source pauses may produce encoded silence and legitimately increase input underruns. It does not record audio. The refill timer uses Windows 10 version 1803 or newer high-resolution waitable timers.

`test_speaker_layout.ps1 -ProbeEndpoint '<your-virtual-render-ID>'` queries DirectSound and XAudio2. The native test's explicit `--reproduce-reboot-loss` mode temporarily removes speaker assignments, then restores 5.1; stop the bridge before that mode. It is an integration reproducer, not a startup command.

## MSI

The existing builder expects local dependencies at these paths, excluded from Git:

- `surround/source/third_party/ffmpeg/`: shared development/runtime files.
- `surround/vbcable/`: complete original VB-CABLE package45.
- `package/WIN10/`: complete original C-Media installer tree.
- `surround/installer/toolchain/wix/`: WiX 3.14 `candle.exe`, `light.exe` and its UI extensions.
- Visual Studio's installed x64 redistributable runtime.

Vendor download/provenance links are retained in `surround/installer/Third Party Notices.txt`. Preserve original media and publisher signatures. Do not assume permission to publish a bundled vendor installer simply because the source repository can be shared.

```powershell
& .\surround\installer\Build-Msi.ps1 -DevelopmentUnsigned
& .\surround\installer\Test-Msi.ps1 -DevelopmentUnsigned -InstallRoundTrip
```

The round-trip test installs into the project's validation folder, uninstalls afterward, and checks that the working bridge's defaults and startup shortcut were preserved. Build output, staging copies and validation logs are local artifacts, not source files.

`Test-Msi.ps1 -DevelopmentUnsigned -InstallRoundTrip -UpgradeFromMsi '<previous-msi-path>'` also tests upgrading a previous release installed in its default folder. It refuses to overwrite an existing previous-version folder. The new package remembers custom install folders, and its removal test omits `INSTALLFOLDER` to verify normal uninstall. Older releases require their original custom folder to be supplied during removal if their default folder was changed.

To build a package while the live engine is running, use a separate build directory and pass its Release folder to the existing builder. This avoids replacing the active executable or its DLLs:

```powershell
cmake -S surround/source/engine -B surround/source/engine/build/package -G "Visual Studio 17 2022" -A x64 "-DVAC3_VERSION=0.1.15-local"
cmake --build surround/source/engine/build/package --config Release
& .\surround\installer\Build-Msi.ps1 -DevelopmentUnsigned -ReleaseDirectory "$PWD\surround\source\engine\build\package\Release"
```
