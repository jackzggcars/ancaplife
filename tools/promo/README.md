# ANCAP LIFE promo video

A 23-second 9:16 short made from real gameplay. Three scripts, re-runnable end to end.

| Step | Command | What it does |
|---|---|---|
| 1. Capture | `python3 -m http.server 8770` (repo root) then `python3 tools/promo/capture.py [shots…]` | Opens the game headless on a virtual clock (`vclock.js`), builds a demo empire with the game's own functions (shops in London, New York, Paris, Tokyo, Berlin and Chicago, staff, kit, a tower under construction), then flies scripted cameras and saves every frame to `frames/<shot>/`. The game's UI is hidden and a large net-worth counter is shown instead. |
| 2. Edit | `python3 tools/promo/edit.py` (`--hook N`, `--all-hooks`) | Upscales to 1080×1920, smooths 15→30 fps by frame blending, adds captions, punch-ins, flash cuts and a shake, then renders `out/ancap-life-promo.mp4` with the soundtrack (loudness-normalised to −14 LUFS). |
| 3. Sound | (called by edit.py) `audio.py` — includes a voice-over made offline with Kokoro TTS (`pip install kokoro-onnx soundfile`, model files from the kokoro-onnx GitHub releases in `$KOKORO_DIR`; `--no-vo` skips it) | An original 120 BPM track plus ka-ching, coin, pop, whoosh and boom effects, synthesised with numpy, so there are no licences. The music ducks under key sound effects. |

To change timing, wording or sound cues, edit `TIMELINE`, `HOOKS`, `captions()`, `cues()`, `PUNCH` and `FLASH_AT` in `edit.py`. Cuts land on the beat (0.5 s at 120 BPM).
Capture settings use environment variables: `PROMO_W`/`PROMO_H` (default 720×1280), `PROMO_FPS` (15), `PROMO_URL`. On a real GPU you can capture at 1080×1920 and 30 fps.
To use a licensed track instead, replace `promo-audio.wav` or swap `audio.music()` for a loaded file.
