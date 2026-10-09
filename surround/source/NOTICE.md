# Third-party notices & attributions

SurroundForge's native engine is adapted from strepto42/virtual-ac3-encoder v0.1.5,
commit `3be5ba878f9689b0257c03ff4759d19cdf552cb5`. Its original MIT license is retained
in `LICENSE`. Binary dependencies and vendor installers are not committed to this
source repository; they remain separate local dependencies.

## Upstream experimental driver (not used or included here)
The upstream project includes a driver derived from Microsoft's
**Windows-driver-samples** "SimpleAudioSample" (MIT, Copyright Microsoft Corporation).
That experimental driver is not part of SurroundForge's source snapshot or tested
runtime. The verified path uses the existing signed VB-Audio and C-Media drivers.

## Engine design — `engine/`
The real-time encode/forward design (output clock as master, lock-free ring buffer, periodic
drift-trim) is modeled on **SoundPusher** by Daniel Vollmer
(<https://codeberg.org/q-p/SoundPusher>), **MIT License**. No SoundPusher source is copied; it
is reimplemented for Windows/WASAPI against the modern FFmpeg API.

## FFmpeg (external dependency)
The engine dynamically links **FFmpeg** libraries (`libavcodec`, `libavformat`, `libavutil`,
`libswresample`) for AC3 encoding and IEC 61937 muxing. FFmpeg is licensed under the
**LGPL-2.1-or-later** (the configuration used here). FFmpeg is **not** included in this repo;
`scripts/fetch-ffmpeg.ps1` downloads a prebuilt shared (LGPL) build. See
<https://ffmpeg.org> and <https://www.ffmpeg.org/legal.html>.

## doctest (vendored)
`third_party/doctest/doctest.h` is the **doctest** single-header test framework by Viktor Kirilov
(<https://github.com/doctest/doctest>), **MIT License**. It is vendored (committed) so the unit
tests build without a separate fetch.

## VB-CABLE (runtime dependency, binary not committed)
**VB-CABLE** by VB-Audio Software (<https://vb-audio.com/Cable/>) supplies the virtual
input for the verified runtime. It is VB-Audio donationware; its original license and
publisher terms apply. The private migration MSI retains the original vendor package,
but this Git snapshot contains no VB-CABLE binary.

## Private migration installer dependencies
C-Media's original installer, Microsoft's redistributable runtime and the FFmpeg
runtime libraries are local inputs to the MSI builder. Their provenance and notices
are recorded in `../installer/Third Party Notices.txt` and `../installer/FFmpeg-Version.txt`.

## Reference only (not distributed)
- `jakemoroni/audio_async_loopback` — referenced for Windows S/PDIF AC3 loopback timing.
- Kodi / xbmc AudioEngine (GPL-2.0-or-later) — read for WASAPI passthrough patterns; **no code copied**.
