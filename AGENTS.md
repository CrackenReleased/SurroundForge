# SurroundForge operating notes

Before code work on this machine, read `E:\AI_Hub\AGENTS.md`, especially §20. Execute directly; do not create planning artifacts.

- Keep the verified audio path: six assigned 48 kHz channels, Windows gain/mute before AC3, and encoded optical transport. Do not substitute stereo upmixing for real game surround.
- Device IDs come from destination-PC configuration or enumeration. Never hardcode this machine's IDs or user profile paths in tracked files.
- Treat optical/device setup and live tests as host operations. Live fixtures must restore volume/mute and defaults. Never stop unrelated processes or change security settings.
- Retain upstream license/provenance. Keep vendor media, builds, MSI files and private diagnostic state outside Git.
- Use the existing regression tests appropriate to a change. Run `surround/tests/test_repository_hygiene.ps1` before committing.
- `what_and_how_log.md` and `INSTALLATION.md` are private local continuity records; `README.md`, `docs/` and `changelog.md` are the reusable documentation.
- The local release is v0.1.10. User confirmed game surround working after this repair; do not claim independent coverage of every game or hardware combination.
