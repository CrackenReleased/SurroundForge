# SurroundForge source operating notes

Before code work, read `E:\AI_Hub\AGENTS.md` §20 and the project-root `AGENTS.md`. Canonical checkout: `E:\SurroundForge`; canonical docs: root README, docs/, changelog and source NOTICE.md.

- Preserve six assigned 48 kHz channels and apply Windows gain/mute before userspace AC3 encoding. Keep timer/padding-driven optical refill and complete bursts; never restore USB event cadence as the output clock.
- Driver source is render-only WaveRT, Microsoft SimpleAudioSample-derived. Its WDK build, Microsoft signing and live integration are unverified. Kernel mode must never load FFmpeg.
- Use modern FFmpeg APIs and existing native/mock regressions. Do not infer healthy audio from a responsive heartbeat alone.
- Resolve paths relative to the script/source directory. Never commit endpoint IDs, user profiles, private ownership state, vendor media or generated builds.
- Follow docs/BUILD.md for fresh build directories after a move. Do not replace the active encoder or install a driver during an unrelated review.
- Preserve licenses/copyright headers. Use a `codex/` feature branch and merge a reviewed PR after CI passes. The current CI builds/tests the user-mode engine; no automatic release workflow or driver certification exists.