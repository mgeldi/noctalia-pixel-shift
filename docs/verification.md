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

## Second round (same evening): responsiveness and measurement

| Check | Before | After |
|---|---|---|
| Lab: first open | 4.9 s (two renders: the theme colour arrived late) | 1.5 s, one render |
| Lab: view or mode switch | 3.5–4.3 s (full rebuild, up to 1 s tick wait) | ~33 ms (cached, background warm-up) |
| Lab: hotspot switch | 4.2 s | 53–65 ms |
| Lab: switch to DP-3 | 9.0 s | 33 ms (warmed in the background) |
| Click during a render | lost | picked up by the next render |

Measured with the `timing on` IPC event while driving the lab over IPC.

- DP-3's start section had been measured at 0.375 (then 0.75) instead of 1.5.
  Dumped capture pairs showed the whole section moving by exactly 12 px; a
  1 px sliver next to the ignored CPU digits had set the factor of the whole
  group. Factors are now voted by change width, shifts must be ones a spacer
  can cause, and the all-spacers capture vetoes spurious spacers. DP-3 now:
  start ×1.5, centre ±0.75, end −1.5, verify error 0.04–0.09 (was 0.44–0.59).
- Covered bar: with a fullscreen video on DP-2, a rescan first saw "nothing
  moved" (kept the old measurement, as intended), then accepted a frame whose
  motion lined up with a spacer shift (verify error 15632). Such measurements
  are now rejected, and retries look before they measure while the bar stays
  covered.
- Unit tests: 108 passed, kernels in sync.

## 1.2.0 (2026-10-01): fullscreen windows

- Cause, from Noctalia's log: every vertical step (every 30 min) and every
  measurement with the override on reloaded the config, and each reload
  recreated the bar on both outputs (`[bar] creating #0 "main" on DP-2` / `DP-3`).
  Hyprland showed the new bar above a fullscreen game or video until the user
  toggled fullscreen. Spacer width changes never recreate the bar.
- Cost of asking: `hyprctl --batch "j/monitors;j/clients"` took about 1.8 ms
  (9 KB of JSON); a grim strip capture about 5.9 ms, and an image-based check
  needs two.
- Live, with a real fullscreen `foot` window on DP-3 (`fullscreen: 2`):
  - the debug line showed `fullscreen=hyprland:DP-3`;
  - a pending vertical step waited ("vertical step waits, a fullscreen window
    is open on DP-3"), logged once;
  - `sample` skipped DP-3 ("sample skipped on DP-3 (fullscreen window)") and
    sampled DP-2 (133 samples, was 132);
  - `rescan` on DP-3 was postponed ("measuring DP-3 later, a fullscreen window
    is open") and retried once a minute without logging again;
  - horizontal widths kept changing on both outputs;
  - no bar was recreated while the window stayed fullscreen;
  - when the window left fullscreen, the postponed DP-3 measurement ran
    (19:27:36, verify error 0.03) and the vertical override went back on
    (19:28:08), with one bar recreation and nothing fullscreen.
- Unit tests: 141 passed, kernels in sync; `noctalia plugins lint`: 0 errors,
  0 warnings.

Not exercised live: Sway (parser unit tests only).

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
