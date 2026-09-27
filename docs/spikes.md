# Spike results (2026-09-27, Noctalia 5.1.0, Hyprland, DP-2 1× + DP-3 1.5×)

| # | Question | Result | Decision |
|---|---|---|---|
| S0 | Plugin API / require | Noctalia 5.1.0 supports plugin API 3–30 and refuses 32. `require` must be relative and end in `.luau`; the standalone luau CLI rejects the suffix. | `plugin_api = 30`; sources use `.luau`, `tools/test.sh` tests a copy with the suffix stripped. `noctalia.getColor` (API 31) is feature-detected. |
| S1 | Spacer relayout, spacing | Widening every spacer by 8 px moved the start group +8, the end group −8, the centre 0 (both centre spacers grew). A 0-width spacer still takes one `widget_spacing` (start/end moved 10 px inward when the spacers were added). | README tells users the spacer adds one widget spacing; drop an adjacent `gap` to compensate. |
| S2 | grim geometry and timing | Logical geometry, physical output: `2560,0 2560x40` on DP-3 gives 3840×60. A capture takes < 10 ms. **`noctalia.outputs()` reports DP-3 with scale 2** (integer buffer scale), not 1.5. | Engine derives the real scale from the capture (`image width / logical width`). |
| S3 | `ui.image` reload | Rewriting the same file keeps showing the old image; a new path updates immediately. Children of a column stretch across its width. | Unique file name per render (already designed); image containers use `align = "start"`. |
| S4 | Vertical trick | `margin_edge + 2, thickness − 2` moved the content down exactly 1 px; window geometry unchanged (`hyprctl clients`); `getSetting` reflects the override. The first frame after `config-reload` shows the bar missing (a visible blink). | Vertical stays opt-in (off by default) with an explicit note about the blink; vertical step 30 min instead of 15. |
| S5 | Luau speed | Full 2560×42 risk map: 57 ms interpreted, 16 ms with native codegen (luau 0.740 CLI). | Optimiser evaluates per-group windows with a cache; no downsampling needed. |
| S6 | Tables in shared state | Nested tables and lists set by the service arrive intact in the panel. | `lab:model` as one table. |
