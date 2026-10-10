# Build and verify SurroundForge — v0.1.16-local, migration revision 1

The local audio runtime is v0.1.15-local; release tooling and the latest development MSI remain v0.1.11. The runtime adds device-space-driven optical refill, frame delivery counters, worker failure handling, an owned recovery supervisor, packet integrity checks and bounded health diagnostics. No new MSI was built for this local runtime update. [Signing setup and free distribution options](SIGNING.md) describe the outstanding identity/vendor requirements. Public MSI creation requires verified company signing; examples below explicitly build development packages.

The working audio installation is Windows x64. The native engine uses C++17, Visual Studio 2022 Build Tools with a Windows SDK, CMake, and dynamically linked FFmpeg libraries. Python 3 is used for several integration tests. WiX 3.14 is used to build the MSI. The custom WaveRT driver source is included separately and requires the Windows Driver Kit; the verified live route still uses signed vendor drivers.

From the repository root, obtain the FFmpeg development files using the existing script:

```powershell
& .\surround\source\scripts\fetch-ffmpeg.ps1 -Prefer master
cmake -S surround/source/engine -B surround/source/engine/build -G "Visual Studio 17 2022" -A x64 "-DVAC3_VERSION=0.1.16-local"
cmake --build surround/source/engine/build --config Release
ctest --test-dir surround/source/engine/build -C Release --output-on-failure
```

The download is a rolling LGPL shared build. The original working build's version and provenance are recorded in `surround/installer/FFmpeg-Version.txt`; a later download is not an exact reproduction of that dependency. Do not download over the DLLs of a running encoder: stop the owned bridge first.

Some PowerShell build/test helpers locate Visual Studio Build Tools' bundled CMake at its normal installed path. If your installation differs, adapt that path or provide CMake on PATH. This repository has not been tested as a clean build on another computer.

## Tests

Run the comprehensive offline test suite (all native, mock & regression tests):

```powershell
& .\Run-Tests.ps1 -Suite Offline
# Use the freshly relocated build without replacing the running engine:
& .\Run-Tests.ps1 -Suite Offline -EngineBuildDirectory .\surround\source\engine\build\migration
```
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
cmake -S surround/source/engine -B surround/source/engine/build/package -G "Visual Studio 17 2022" -A x64 "-DVAC3_VERSION=0.1.16-local"
cmake --build surround/source/engine/build/package --config Release
& .\surround\installer\Build-Msi.ps1 -DevelopmentUnsigned -ReleaseDirectory "$PWD\surround\source\engine\build\package\Release"
```

## Canonical directory and moved builds

This machine's checkout is now `E:\SurroundForge`; `E:\AI_Hub\Tools\audio-diagnostics` is the retired location. Source launchers resolve their location from `$PSScriptRoot`; device IDs belong in the ignored `surround/bridge.conf`. The observed engine, supervisor and `SurroundForge.lnk` startup shortcut already use the new directory.

CMake caches and generated Visual Studio projects are not relocatable. Do not edit cached absolute paths or replace executables while audio is running. Configure a fresh, ignored build directory:

```powershell
Set-Location E:\SurroundForge
cmake -S surround/source/engine -B surround/source/engine/build/migration -G "Visual Studio 17 2022" -A x64 "-DVAC3_VERSION=0.1.16-local"
cmake --build surround/source/engine/build/migration --config Release
ctest --test-dir surround/source/engine/build/migration -C Release --output-on-failure
```

The migration review regenerated the existing primary/package CMake configurations with `cmake --fresh` and rebuilt the generated speaker-layout fixture. The `build/Release` binaries remain the live runtime until an intentional Stop/build/Start maintenance session. Use `Run-Tests.ps1 -EngineBuildDirectory` to test fresh binaries; do not replace the running engine for documentation verification. If a generated speaker-layout test cache refers to the old location, remove only `surround/tests/output/speaker-layout-build` and let the existing test rebuild it.

If startup points to a retired directory on another installation, deliberately stop the owned bridge before moving it, then use `Bridge.ps1 -Action EnableStartup` from the new location. Private state and device configuration must stay with that installation; never copy this machine's device IDs into a public checkout.

## Custom WaveRT driver

Read [the driver README](../surround/source/driver/README.md). The solution is `surround/source/driver/SimpleAudioSample.sln`, not beneath `Source/Main`.

```powershell
& .\surround\source\driver\Build-Driver.ps1 -Configuration Release -Platform x64
& .\surround\source\driver\New-AttestationCab.ps1 -VerifySourceOnly
# Only after a successful WDK build:
& .\surround\source\driver\New-AttestationCab.ps1 -DriverPackageDir "$PWD\surround\source\driver\x64\Release\package"
```

Source-only verification checks metadata; it does not compile, sign or prove the driver loads. CI currently builds the user-mode engine and checks driver metadata only. No native-driver binary package is present on this machine. The private upstream test-install/uninstall scripts are legacy development helpers, excluded from Git, and are not the supported installation flow. Setup/MSI integration of a Microsoft-signed native package remains outstanding.