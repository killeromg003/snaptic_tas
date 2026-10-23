# SNAPTIC-TAS

A minimal practice tool for **SNAPTIC 0.91.0.0** (Godot 4.7.1, Windows x64).

## Features

| Feature | Status |
|---------|--------|
| Pause / resume (F6) | ✅ |
| Frame-step (F7) | ✅ |
| Slow-motion 1× / 0.5× / 0.25× (Shift+F6) | ✅ |
| Always-on HUD with tick/hitch/FPS info (F12) | ✅ |


## Non-Features

- No record / replay
- No snapshots / rewind
- No run-file save/load
- No true reverse execution
- No online run IDs
- No particle / tween / audio / Jolt snapshotting
- No game content in this repository

## Requirements

- **SNAPTIC 0.91.0.0** (Windows x64)
- **Godot 4.7.1** (engine version `4.7.1.stable.custom_build`)
- **GDPatch 0.2.4** (included as `winmm.dll`)
The tool **refuses to run** on version mismatch and **asserts expected script paths exist** — no silent patching.

## Installation

1. Place `winmm.dll` (GDPatch 0.2.4) next to `snaptic.exe`
2. Create `GDPatch/config.toml` with the encryption key:
   ```toml
   [engine]
   encryption_key = "eb74e928c34749204a5bae90975743d700c5a38827c0f51bdde11a8747a9e6e0"
   include_godot = true
   ```
3. Extract the mod zip into `GDPatch/mods/snaptic_tas/`
4. Launch `snaptic.exe` — the HUD appears in the top-left

## Uninstallation

- Delete `winmm.dll`
- No files outside `GDPatch/` are modified

## Hotkeys

| Key | Action |
|-----|--------|
| **F6** | Pause / resume |
| **Shift+F6** | Cycle slow-mo: 1× → 0.5× → 0.25× → 1× |
| **F7** | Single frame step (while paused) |
| **F12** | Toggle HUD visibility |


## Known Issues

- **Hitstop** — neutralized during TAS by clearing `HitstopComponent.node_to_pause`; may affect feel.
- **Render-rate non-determinism** — mitigated by `max_fps=240`, vsync off, and hitch detection (flags frames with >1 physics tick).
- **Jolt Physics determinism** — not compiled with `JPH_ENABLE_DETERMINISM`; physics may drift across sessions.

## Version Matrix

| SNAPTIC-TAS | SNAPTIC | Godot | GDPatch | Status |
|-------------|---------|-------|---------|--------|
| 0.2.0 | 0.91.0.0 | 4.7.1 | 0.2.4 | Current |

## Credits

- **GDPatch** — runtime GDScript patching (MIT)
- **GDRE Tools** — PCK extraction / script recovery (MIT)
- **SNAPTIC** — the game this tool targets

## License

MIT — see [LICENSE](LICENSE)
