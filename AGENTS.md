# SurroundForge operating notes

Before code work on this machine, read `E:\AI_Hub\AGENTS.md`, especially §20. Execute directly; do not create planning artifacts.

- Keep the verified audio path: six assigned 48 kHz channels, Windows gain/mute before AC3, and encoded optical transport. Do not substitute stereo upmixing for real game surround.
- Device IDs come from destination-PC configuration or enumeration. Never hardcode this machine's IDs or user profile paths in tracked files.
- Treat optical/device setup and live tests as host operations. Live fixtures must restore volume/mute and defaults. Never stop unrelated processes or change security settings.
- Retain upstream license/provenance. Keep vendor media, builds, MSI files and private diagnostic state outside Git.
- Use the existing regression tests appropriate to a change. Run `surround/tests/test_repository_hygiene.ps1` before committing.
- `what_and_how_log.md` and `INSTALLATION.md` are private local continuity records; `README.md`, `docs/` and `changelog.md` are the reusable documentation.
- Release tooling/latest development MSI is v0.1.11; local audio runtime is v0.1.15-local with timer/padding-driven optical delivery, packet integrity, worker failure detection and owned recovery. Never reintroduce exclusive USB event cadence as the audio clock. Refill whole AC3 bursts only; nonmultiple device capacity must not introduce carrier stuffing. Use submittedFrames and elapsed time to verify 48 kHz delivery, not renderCycles (variable-sized refills). Start enables supervision; Stop cancels it first, DisableStartup disables supervision while current audio continues. Run mock supervisor and explicit live recovery tests for lifecycle changes. User confirmed clear audio after the cadence repair; overnight/hardware coverage is unverified.
- Default MSI builds require company publisher signing; unsigned development builds never go to dist. No public signing identity is enrolled. Original C-Media installer wrapper is unsigned, so public bundling is blocked. See docs/SIGNING.md; preserve original vendor media and never substitute self-signing for public trust.
