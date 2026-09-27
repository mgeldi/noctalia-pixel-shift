# Pixel Shift: burn-in protection for the Noctalia bar

Status: approved design (brainstorming session 2026-09-27)
Plugin id: `mgeldi/pixel-shift` · Plugin name: **Pixel Shift** · Panel: **Burn-in Lab**

## 1. Goal

OLED panels burn in where bright pixels stay put for long periods. A status bar is
the worst case: the clock, workspace pills, dividers and tray icons sit on the same
subpixels for hours every day.

Pixel Shift moves the bar's content by a few pixels over the day. It does not do this
blindly. It **measures the user's own bar**, simulates OLED wear, finds the shift
strategy that minimises visible burn-in for that bar, and shows the result in a lab
panel. The lab also shows the risk that shifting cannot remove (for example a solid
fill wider than the shift range), so the user can adjust the bar's look.

Success criteria:

- Works on any Noctalia bar layout without editing the user's bar config.
- The lab explains the risk in a way a non-expert understands in seconds (ghost
  preview with glowing hotspots in the theme colour).
- The strategy is optimised automatically and re-optimised when the bar changes.
- Accepted into `noctalia-dev/community-plugins`.

## 2. Constraints (verified facts)

- Noctalia 5.1, plugin API level **32**. Plugins are trusted, unsandboxed Luau.
- A plugin can read settings (`noctalia.getSetting`) but has no API to write them.
- A plugin cannot move other widgets. It can render its own widget at any size
  (`barWidget.render(ui.box{width=…})`), which pushes the widgets after it.
- There is no screenshot API. `grim` (wlr-screencopy) is the capture tool; it works on
  Hyprland, niri, sway, labwc and mangowc.
- `ui.image` shows local files (BMP decoder present); `ui.graph` draws up to two line
  series with pointer events; there is no absolute positioning (flex rows/columns only).
- Luau runtime has `buffer` (f32 read/write), coroutines, `string.pack`, `bit32`, and
  `require` for relative modules (API 22).
- `noctalia.pluginDataDir()` is the per-plugin persistent directory.
- Config directory: `$NOCTALIA_CONFIG_HOME`, else `$XDG_CONFIG_HOME/noctalia`, else
  `~/.config/noctalia`. All `*.toml` files there are merged alphabetically.
- The official plugin repo does not accept third-party plugins. The target is
  `noctalia-dev/community-plugins` (one plugin per PR, CI validates manifest,
  README, translations and thumbnail; reviewers read every line).

## 3. Entries

| Entry | Id | Job |
|---|---|---|
| Bar widget | `spacer` | Invisible box. Its width is the current offset for its slot. The user places spacers in the bar. |
| Service | `engine` | Scans, samples exposure, optimises, plays the strategy, owns all state. |
| Panel | `lab` | The Burn-in Lab UI. |
| Shortcut | `toggle` | Control-center tile: pause / resume shifting. |

Recommended spacer placement: first item of `start`, last item of `end`, first and
last item of `center`. Optional extra spacers between groups add independent motion.
The plugin never edits the bar layout itself; the lab shows a placement guide and a
button that opens the bar settings.

## 4. Wear model and risk

All maths works on a **bar image**: the bar strip of one output plus 8 px below it
(the region under the bar, so the bar's own bottom edge is judged against real
desktop brightness), in physical pixels.

### 4.1 Wear

- sRGB → linear light per channel.
- Wear rate per pixel: `w = Σ_c k_c · L_c^n`, `n = 1.6` (luminance acceleration from
  published OLED lifetime curves).
- Panel profile (setting) selects the channel weights:
  - `generic` (default): `k = (0.55, 0.75, 1.0)`, blue wears fastest.
  - `woled`: white subpixel carries `min(R,G,B)`: `w = 1.0·m^n + Σ k_c·(L_c − m)^n`
    with `k = (0.5, 0.6, 0.9)`.
  - `qdoled`: all channels driven by blue emitters: `k = (1, 1, 1)`.
- Numbers are **relative**. The plugin never claims hours to burn-in.

### 4.2 Exposure

`E(x,y)` = time-weighted mean wear over all shift states and all exposure samples.

Wear is non-linear, so blurring the image and then wearing it would be wrong. The
model splits wear into two layers:

- `w_bg` = wear of the static background (bar surface over wallpaper),
- `Δw = wear(composite) − wear(background)` = the extra wear caused by content,
  computed at offset 0. This layer moves with its slot.

For a strategy where slot `i` spends equal time at every offset `0..W_i`:
`E = w_bg + boxblur(Δw)` over `W_i · f_i` pixels inside slot `i`'s mask
(`f_i` = measured movement factor, e.g. 1.0 for start/end, ±0.5 for a centred
group). Vertical shift adds a box blur of `Δw` over `0..V` rows. The approximation
is tight because the background varies slowly along the bar. Box blurs use prefix
sums, so one evaluation is O(pixels).

### 4.3 Risk

Burn-in is visible where wear **differs** between neighbours:

`R = |E − G_1.5 * E| + 0.5 · |E − G_10 * E|`

- fine scale (σ = 1.5 px): text strokes, icon edges
- coarse scale (σ = 10 px): blocks, pill cores, band edges
- Gaussians approximated by three box blurs (O(pixels)).

**Score** (0–100): 99th percentile of `R` over the bar rows plus the first 2 rows
below the bar (the bar's own bottom edge), divided by the same statistic for a
reference image (1 px pure-white line on black, no shift) × 100. Shown as `57 → 15`
and `−74%`. Rows further below only feed the coarse blur (real desktop brightness
next to the bar) and "outside the bar" info hotspots; they never count toward the
score.

### 4.4 Hotspots

Pixels whose risk under the active strategy exceeds a threshold are grouped into
regions (column runs merged across ≤ 6 px gaps). Each region gets a cause:

| Cause | Test | Hint |
|---|---|---|
| wider than shift range | lit plateau wider than `W_i · f_i` | lower fill opacity, outline style |
| horizontal edge | risk concentrated on rows, not columns | enable vertical shift |
| very bright | mean linear luminance > 0.7 | dim colour, thinner font weight |
| dynamic content | high variance across exposure samples | "estimate drops as sampling continues" |
| outside the bar | region lies below the score rows (window borders etc.) | info only, not fixable by the plugin |

A region is named by its slot and position ("start group, x 503–642"). The lab lists
the top 4.

## 5. Lab visuals

### 5.1 Views

- **Bar**: the latest capture.
- **Ghost** (default): what the bar leaves on a flat mid-grey screen after long use.
  `g = 0.60 − 0.40 · (E / E_ref)^0.8`, scaled by 0.72, same `E_ref` for every view so
  comparisons are honest.
- **Risk**: dimmed bar with the risk ramp.
- Each view is shown for **No shift** or **Strategy** (segmented control).

### 5.2 Hotspot glow

Glow brightness is proportional to risk on **one absolute scale** for every view:

- `t = clamp(R / R_top)`, `R_top` = 99.9th percentile of the no-shift risk.
- bloom: `t ← clamp(t + 0.35 · blur_1.2(t))`
- alpha: `smoothstep(0.16, 0.55, t)`
- colour: glow ramp at `t`.

Result (verified on the author's bar): without shifting, every bright edge glows hard;
with the strategy only overlaps and horizontal edges glow.

### 5.3 Theme colours

Everything follows the active Noctalia theme. The glow ramp is derived from
`noctalia.getColor("primary")`: take its OKLCH hue, boost chroma to
`clamp(max(1.6·C, 0.13), 0.13, 0.22)`, and ramp lightness 0.50 → 0.90. So a near-grey
or a dark-red primary still glows bright and coloured. The ramp is rebuilt when the
palette changes. Chrome uses palette roles (`surface`, `surface_variant`,
`on_surface`, `primary`, …).

### 5.4 Layout (concept C v5)

1. Header: title, output chip (`DP-2 · 2560×34`), exposure chip
   (`Exposure: 14 samples · 2.3 h`), view segmented control, No shift / Strategy
   control, rescan button, output selector when several outputs have spacers.
2. Overview: the whole bar as **two exact halves** (0–50 %, 50–100 %), identical
   width, ghost/risk image, numbered hotspot pins (glow colour) placed with spacer
   rows, a frame marking the inspected region.
3. Inspector (left): 4× crop of the selected hotspot, **No shift** above
   **With strategy** (the strategy includes vertical when allowed). Updates live.
4. Sidebar (right): score card (`57 → 15`, `−74%`, legend) and the hotspot list with
   cause tags and fix hints; the selected hotspot is expanded.
5. Strategy card:
   - `Auto | Manual` control, status (`✓ optimized 12:06 · 918 strategies · 4 s`),
     Apply.
   - Risk-vs-movement curve (`ui.graph`: horizontal only dashed/secondary, with
     vertical in glow colour) with the auto pick marked.
   - `Calm ↔ Max protection` slider along the curve.
   - Chosen parameters as chips (`Start 6 px · Center 5 px · End 6 px ·
     Vertical ±2 px · 1 px / 4 min`).
   - `Allow vertical shift` toggle (opt-in, see 7.3).
   - Manual mode reveals one slider per slot plus vertical range.
   - While optimising: progress bar, `best so far`, Cancel.
6. Onboarding state (no spacers): placement guide + "Open bar settings".
7. Error states: grim missing, capture failed, vertical override not effective.

Images are written by the plugin as BMP into the data dir with a new file name per
render (cache-safe), older files removed.

## 6. Measurement

### 6.1 Spacer registry

Each spacer instance creates a random id at load and registers
`{id, output, vertical}` in `noctalia.state` under `spacers`. The engine watches the
registry. A spacer renders `ui.box{width = base + offset}` (height 1, transparent);
in a vertical bar it uses `height` instead.

### 6.2 Scan (per output, ~1 s)

1. Freeze: all spacers on the output to width 0.
2. Baseline capture: `grim -t ppm -g "<x>,<y> <w>x<h>" <file>` of the bar strip + 8 px.
3. For each spacer: set width +8, wait for the widget's render acknowledgement plus
   one frame, capture, restore. The difference to baseline (column cross-correlation)
   gives the slot's pixel mask and movement factor `f_i`.
4. Separate content from background: pixels that moved are content; the background
   under them is interpolated from unmoved neighbours in the same row.
5. Verification: all spacers at +8, capture, compare with the model prediction. If
   the error exceeds a threshold, fall back to measuring each offset directly
   (captures at every offset 0..W_max per slot, ~5 s; the lab warns first).
6. Restore the active strategy.

Triggers: first run, Rescan, and automatically when the spacer registry or a bar
layout fingerprint changes (hash of `bar.main.*` settings polled once a minute,
thickness, output geometry, scale; `onOutputsChanged`).

### 6.3 Exposure sampler

- Every 10 min (setting), capture the bar strip of each output with spacers.
- Skip near-black frames (output off / locked).
- Undo the known current offsets per slot, then add the frame (linear light) to a
  running mean.
- Stored per output and layout fingerprint in the data dir as a binary f32 image plus
  JSON metadata (count, time span). **No individual screenshots are stored.**
- A per-pixel variance accumulator marks dynamic content (window titles, media).
- A layout change starts a new mean.

## 7. Strategy

### 7.1 Parameters

Per slot `i`: range `W_i` (0..16 px). Global: vertical range `V` (0..2 px, only when
allowed), step interval per slot. Default step 4 min; slots use slightly different
intervals (4:00, 4:37, 5:13, 5:47, …) so they never move in lockstep and the joint
distribution fills.

### 7.2 Optimiser

- Objective: `J = score(W, V) + λ · m` with movement `m = max_i(W_i · |f_i|) + V`
  in px (the largest visible displacement of any group plus the vertical range).
- Coordinate descent over `W_i` (and `V`), starting from 0, then a budget sweep
  `B = 0..16` (each `W_i ≤ B`) to produce the risk-vs-movement curve (two series:
  with and without vertical).
- Auto pick: minimum of `J` with λ = 0.7 score points per px ("Balanced"). The
  `Calm ↔ Max protection` slider maps to λ ∈ [3.0, 0.1].
- Runs as a coroutine in slices of ~4 ms per update tick; results stream into the lab.
- Triggers: after every scan, nightly (first tick after 04:00) with the day's exposure,
  when the panel profile or vertical permission changes, on "Re-optimize".
- Evidence from the author's bar (prototype): horizontal 57 → 27 at 2 px, 20 at 6 px,
  16 at 16 px; with vertical ±2 px: 32 at 0 px, 15 at 6 px, 11 at 16 px.

### 7.3 Player

- Offsets derive from wall-clock time: `o_i(t) = triangle(t / step_i, W_i)`. No
  stored phase, so restarts and multiple outputs stay consistent.
- The engine publishes `offsets:<output>` in `noctalia.state`; spacers watch it.
- **Vertical (opt-in, off by default).** When allowed, the engine stores the user's
  base `margin_edge` (M0) and `thickness` (T0), then writes its own override
  `zz-pixel-shift.toml` in the config dir with `margin_edge = M0 + 2v`,
  `thickness = T0 − 2v` for content offset `v`, and runs
  `noctalia msg config-reload`. Reserved space stays `M0 + T0`, so windows keep their
  size (to be confirmed by spike S4). Vertical steps are slow (15 min). Turning the
  option off removes the file and reloads. If `getSetting` shows the override has no
  effect (for example GUI overrides in the state file), the lab warns and vertical
  is disabled.
- Pause (tile, IPC `pause`/`resume`/`toggle`): all offsets 0, vertical override
  removed.

### 7.4 Apply / Revert

The lab previews candidate strategies; Apply makes one active. The last three active
strategies are kept for Revert. Strategies are JSON in the data dir, keyed by output
and layout fingerprint.

## 8. Settings (manifest)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `panel_profile` | select `generic`/`woled`/`qdoled` | `generic` | channel weights |
| `sample_minutes` | int | 10 | exposure sampling interval |
| `step_minutes` | int | 4 | base time per 1 px step |
| `max_shift` | int | 16 | upper bound for any slot range |
| `allow_vertical` | bool | false | enables the vertical override file |

## 9. Architecture

```
pixel-shift/
  plugin.toml
  README.md  thumbnail.webp  translations/en.json
  spacer.luau        bar widget glue
  engine.luau        service glue: state machine, scheduling, IPC
  lab.luau           panel glue: rendering the ui tree
  toggle.luau        shortcut glue
  core/              pure Luau, no Noctalia globals, unit-tested
    ppm.luau         PPM (P6) parser → buffer
    bmp.luau         24-bit BMP writer
    color.luau       sRGB/linear/OKLCH, theme glow ramp
    image.luau       f32 image type, box blur, prefix sums, shifts
    wear.luau        panel profiles, wear map
    risk.luau        risk map, score, reference normalisation
    layout.luau      scan diff → slot masks and factors
    exposure.luau    running mean/variance, un-shifting
    simulate.luau    strategy → exposure → risk
    optimize.luau    coordinate descent, budget sweep, knee pick (coroutine-friendly)
    schedule.luau    triangle waves, per-slot intervals
    hotspots.luau    region grouping and cause classification
    render.luau      ghost / risk / glow compositing, crops, overview halves
```

Glue files hold everything that touches `noctalia`, `ui`, `barWidget`, `panel`,
`shortcut`. The core is testable with the standalone `luau` CLI.

## 10. Error handling

- `grim` missing: lab error state with install hint; engine idles.
- Capture failure or timeout: retry on the next tick with backoff; lab shows the last
  good data.
- No spacers: onboarding state.
- Scan verification mismatch: per-offset measurement fallback.
- Vertical override ineffective: warning, vertical disabled.
- Corrupt data files: discard and rescan.
- Plugin disable/uninstall (`onExit` reason `disable`/`uninstall`): remove the vertical
  override file and reload config.

## 11. Testing

- Unit tests for every `core/` module with the `luau` CLI (Arch `extra/luau`),
  synthetic fixtures only (no real screenshots in the public repo).
- Golden tests: synthetic bars (text-like strokes, a wide solid pill, a thin
  horizontal line) with expected score ordering and hotspot causes.
- Performance test: one simulate+risk evaluation on 2560×42 and 3840×63.
- Live tests in Noctalia through the local plugin source, including multi-monitor
  (DP-2 scale 1, DP-3 scale 1.5).
- `noctalia plugins lint` and the community `validate-plugins.py` before submission.

## 12. Spikes (first implementation step, throwaway)

| # | Question | Decision rule |
|---|---|---|
| S1 | Does changing a spacer's width relayout the bar cleanly? Does a 0-width widget still get `widget_spacing`? | If spacing applies, README tells users to drop one adjacent `gap`. |
| S2 | grim geometry in logical px, output scale, capture time | Use measured values; if capture > 150 ms, lower scan resolution of verification only. |
| S3 | Does `ui.image` reload a rewritten file? | Unique file names per render either way. |
| S4 | Vertical trick: reserved space constant? flicker on reload? override precedence? | If windows resize or the bar flickers visibly, vertical ships disabled with an explanation; the lab still simulates it. |
| S5 | Luau speed of one evaluation | If > 30 ms at 2560×42, optimiser searches on a 2× horizontally downsampled image and renders at full resolution. |

## 13. Release

- Public repo `mgeldi/noctalia-pixel-shift` (MIT): `pixel-shift/` (exactly the
  community directory), `tests/`, `docs/`, CI running the luau tests.
- Submission: fork `noctalia-dev/community-plugins`, add `pixel-shift/`, PR with the
  full disclosure: processes spawned (`grim`, `noctalia msg config-reload`), files
  written (data dir: exposure means, strategies, BMP previews; optional
  `zz-pixel-shift.toml` in the config dir), no network access.
- Tags: `bar`, `panel`, `service`, `shortcut`, `utility`, `hardware`, `hyprland`,
  `niri`, `sway`, `labwc`, `mangowc`.
- Screenshots for the PR are taken with window and media titles blanked.
- Optional follow-up: feature request in `noctalia-dev/noctalia` for a native bar
  pixel-shift, citing the lab's vertical numbers.

## 14. Out of scope

- Per-channel (colour-tinted) burn-in visualisation.
- Shifting anything other than the bar (dock, desktop widgets).
- Absolute lifetime predictions.
- Automatic editing of the bar layout (spacer placement stays manual).
