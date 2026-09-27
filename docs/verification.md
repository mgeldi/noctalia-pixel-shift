# Live verification (2026-09-27, Noctalia 5.1.0, Hyprland)

Machine: DP-2 2560×1440 at scale 1, DP-3 2560×1440 logical at scale 1.5
(`noctalia.outputs()` reports 2). Bar: top, thickness 34, four spacers
(`ps_start`, `ps_center_l`, `ps_center_r`, `ps_end`).

| Check | Result |
|---|---|
| Unit tests | `tools/test.sh`: 67 passed, kernels in sync |
| Lint | `noctalia plugins lint`: 0 errors, 0 warnings |
| Scan DP-2 | 4 groups: start ×1, centre ±0.5, end −1 (two groups). Verify error 0.03. ~16 s wall in 8 ms slices. |
| Scan DP-3 | Physical scale 1.5 taken from the capture: start ×1.5, centre ±0.75, end −1.5 plus −0.75 from the right centre spacer (the end section overflows its slot when the centre grows). Verify error > 0.35 → lab shows "approximate". |
| Optimiser | DP-2 horizontal: 81 evaluations. With vertical allowed: 27 strategies, 267 evaluations, 5.0 s in 628 slices. DP-3 horizontal: 88 evaluations, 3.7 s in 455 slices; with vertical 14.3 s in 1785 slices. |
| Scores | DP-2 58 → 20 (6 px), 34 → 14.7 with vertical ±2 at 6 px. DP-3 52 → 21, 38 → 12.2. The Python prototype predicted 57 → 20 and 32 → 15 for DP-2. |
| Player | Widths follow the triangle schedule; pause sets all to 0, resume restores. |
| Lab | Views bar/ghost/risk, modes, output switch, hotspot selection, bar chart with auto pick, "approximate" note, chips; renders after engine restarts (lab re-sends "open"). |
| Apply / revert | Protection 0.95 + apply → DP-2 ranges {15, 15, 13, 14}; revert → {6, 11, 1, 6}; protection level restored with the strategy. |
| Sampler | Samples written for both outputs (`exposure-*.bin`), no mismatches. |
| Vertical | Override written from the stored base (margin 0 / thickness 34 → 2 / 32); window geometry unchanged; spacer ids and fingerprints unchanged across the config reload (no rescan); disabling removes the file. |
| Reload | Plugin disable/enable restores both scans without measuring again. |

Not exercised live: the lock-screen sample skip (would lock the user's
session), clicking the control-center tile (not placed in this user's
control center), the onboarding and "grim missing" states (spacers and grim
are present). Their logic is small and covered by code review.

Host findings that shaped the code (see the ledger rulings):

- Script callbacks are stopped after ~25 ms of CPU.
- Modules loaded with `require()` run without fast builtin calls (~4× slower
  than the entry script); loop iterations cost ~76 ns each.
- `ui.graph` is an animated sparkline, not a chart.
- `ui.image` caches by path.
- `config-reload` recreates bar widgets; `barWidget.outputName()` is nil in
  state watchers.
- An anchored centre widget pins the whole centre section.
