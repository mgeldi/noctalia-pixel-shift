# Pixel Shift Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Noctalia community plugin `mgeldi/pixel-shift`: invisible spacer widgets that shift bar groups over the day, an engine that measures the user's bar and optimises the shift strategy with an OLED wear model, and the Burn-in Lab panel that visualises the risk.

**Architecture:** Pure Luau core modules (`pixel-shift/core/*`, no Noctalia globals, unit-tested with the standalone `luau` CLI) hold every numeric algorithm. Thin glue entries (`spacer`, `engine`, `lab`, `toggle`) talk to Noctalia: the engine owns all state, captures the bar with `grim`, runs the optimiser in coroutine slices, and publishes offsets and the lab model through `noctalia.state`.

**Tech Stack:** Luau (Noctalia plugin API 32), `grim` for captures, standalone `luau` 0.740 CLI for tests, GitHub Actions CI.

**Spec:** `docs/superpowers/specs/2026-09-27-pixel-shift-design.md`

**Execution note:** The author executes this plan natively in the session that wrote it. Every code block that starts with a `-- file: <path>` line is extracted verbatim into the repo by `tools/extract-plan.py` (Task 1). Later fixes land in the repo files, not back in this plan.

## Global Constraints

- Plugin id `mgeldi/pixel-shift`, directory `pixel-shift/`, `plugin_api = 32`, `version = "1.0.0"` at submission, `license = "MIT"`, `dependencies = ["grim"]`.
- Every `.luau` file starts with `--!nonstrict` (community convention).
- `require` paths are relative and extension-less (`require("./core/image")`); Task 1 verifies Noctalia accepts this, else switches to the form it accepts in every file.
- Core modules never touch `noctalia`, `ui`, `barWidget`, `panel`, `shortcut` globals.
- User-facing strings come from `translations/en.json` via `noctalia.tr`; only English is written.
- Tags only from the allowed list: `bar`, `panel`, `service`, `shortcut`, `utility`, `hardware`, `hyprland`, `niri`, `sway`, `labwc`, `mangowc`.
- Wear exponent `n = 1.6`; profiles generic `(0.55, 0.75, 1.0)`, woled `(0.5, 0.6, 0.9)` + white 1.0, qdoled `(1, 1, 1)`.
- Risk `R = |E − G1(E)| + 0.5·|E − G10(E)|` with three-pass box Gaussians (box radius 1 and 10).
- Score = `100 · p99(R over score rows) / Rref`, `Rref` = risk of a 1 px white line.
- Glow: `t = clamp(R / R_top)`, bloom `+0.35·blur`, alpha `smoothstep(0.16, 0.55, t)`, ramp from theme primary: chroma `clamp(max(1.6C, 0.13), 0.13, 0.22)`, lightness 0.50 → 0.90.
- Ghost: `(0.60 − 0.40·clamp(E/E_ref)^0.8) · 0.72`.
- Auto pick λ = 0.7; slider maps t ∈ [0, 1] to λ = 3.0·(0.1/3.0)^t.
- Step intervals: base `step_minutes` (default 4) × `{1, 1.154, 1.304, 1.446, 1.593, 1.737, 1.879, 2.021}`; vertical step 900 s.
- Vertical override file `zz-pixel-shift.toml` in `$NOCTALIA_CONFIG_HOME` → `$XDG_CONFIG_HOME/noctalia` → `~/.config/noctalia`; `margin_edge = M0 + 2v`, `thickness = T0 − 2v`.
- No network access anywhere in the plugin.
- Public screenshots have window and media titles blanked.

## Review Focus

1. **Fractional output scale (1.5 on DP-3).** Capture geometry is logical, images are physical; factors, kernel ranges and displacements must stay consistent. Tests: `util_test` (captureGeometry at scale 1.5), `layout_test` (probe at scale 1.5 → factor 1.5), `simulate_test` (range rounding).
2. **Screen locked / bar covered while sampling.** Samples that do not show the scanned bar must be skipped, never averaged in. Tests: `exposure_test` (`isBlank`, `matchesBaseline`).
3. **A spacer that moves nothing** (placed at the end of a section). It must be reported, not silently optimised. Test: `layout_test` (slot `moves = false`).
4. **Bottom and side bars.** Row layout, score rows and vertical direction flip. Tests: `util_test` (bottom/left/right geometry and rows).
5. **Missing or corrupt data files after an update.** Must fall back to a rescan, never crash. Tests: `exposure_test` (deserialize garbage → nil), `scanstore_test` (decode garbage → nil).

---

## File Structure

```
tools/extract-plan.py          plan code blocks → files
tools/test.sh                  runs the luau test suite
.tools/bin/luau                local luau 0.740 (gitignored)
.github/workflows/test.yml     CI: luau tests
pixel-shift/
  plugin.toml                  manifest (entries, settings, tags)
  README.md                    community README (template structure)
  thumbnail.webp               960x540 card image
  translations/en.json         every user-facing string
  spacer.luau                  bar widget: invisible box, width = offset
  engine.luau                  service: registry, scan, sampler, optimiser, player, IPC
  lab.luau                     panel: Burn-in Lab UI
  toggle.luau                  control-center tile
  engine/tasks.luau            coroutine task runner (await / sleep)
  engine/capture.luau          grim capture → Rgb8
  engine/store.luau            JSON + blob persistence in the data dir
  engine/vertical.luau         vertical override file writer
  engine/labmodel.luau         renders lab images, builds the lab model
  core/image.luau              f32 images, box filters, shifts
  core/color.luau              sRGB/linear/OKLCH, theme ramps
  core/ppm.luau                Rgb8 raster, P6 parser, transpose
  core/bmp.luau                24-bit BMP encoder
  core/wear.luau               panel profiles, wear maps
  core/risk.luau               risk map, reference, histograms, score
  core/util.luau               config dir, fingerprints, geometry, registry, ids
  core/layout.luau             scan captures → groups, factors, background, layers
  core/scanstore.luau          layout/scan serialisation (pure)
  core/simulate.luau           strategy → exposure → risk; group windows
  core/optimize.luau           cached coordinate descent, curve, pick
  core/schedule.luau           triangle waves, step intervals
  core/exposure.luau           running wear means, variance, blank/match checks
  core/hotspots.luau           hotspot regions and causes
  core/render.luau             ghost / glow / risk views, halves, zoom
tests/testlib.luau             tiny test framework
tests/run.luau                 loads every *_test module
tests/*_test.luau              one per core module
```

---

### Task 1: Scaffold, tooling, local install, require probe

**Files:**
- Create: `tools/extract-plan.py`, `tools/test.sh`, `tests/testlib.luau`, `tests/run.luau`, `tests/smoke_test.luau`
- Create: `pixel-shift/plugin.toml`, `pixel-shift/translations/en.json`, `pixel-shift/spacer.luau`, `pixel-shift/engine.luau`, `pixel-shift/lab.luau`, `pixel-shift/toggle.luau` (stubs, replaced in later tasks), `pixel-shift/core/probe.luau` (temporary)
- Create: `.github/workflows/test.yml`
- Create symlink: `~/.config/noctalia/plugins/pixel-shift` → `~/Projects/noctalia-pixel-shift/pixel-shift`

**Interfaces:**
- Produces: `tests/testlib.luau` API `test(name, fn)`, `eq(a, b, msg?)`, `near(a, b, tol?, msg?)`, `ok(v, msg?)`, `run(filter?)`; `tools/test.sh [filter]`.

- [ ] **Step 1: Write the extractor**

```python
# -- file: tools/extract-plan.py
#!/usr/bin/env python3
"""Write plan code blocks to the repo. A block is extracted when its first
line is `-- file: <path>` (optionally prefixed by `# ` or `// `); the marker
line itself is not written.

Usage: extract-plan.py PLAN [--task N] [PATH ...]
  --task N   only blocks inside "### Task N:" (stub and final versions of a
             file live in different tasks)
  PATH ...   only these repo paths
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
args = sys.argv[1:]
plan = pathlib.Path(args.pop(0))
task = None
if args[:1] == ["--task"]:
    task = args[1]
    args = args[2:]
only = set(args)
text = plan.read_text()
if task is not None:
    m = re.search(rf"^### Task {task}:.*?(?=^### Task |\Z)", text, re.S | re.M)
    if not m:
        sys.exit(f"task {task} not found")
    text = m.group(0)
block = re.compile(r"`{3}[a-z]*\n((?:# |// )?-- file: (\S+)\n.*?)`{3}", re.S)
written = 0
for m in block.finditer(text):
    body, rel = m.group(1), m.group(2)
    if only and rel not in only:
        continue
    content = body.split("\n", 1)[1]
    if rel.startswith("pixel-shift/") and rel.endswith(".luau"):
        # Noctalia requires explicit relative paths ending in .luau
        content = re.sub(r'require\("(\.{1,2}/[^"]+?)(?<!\.luau)"\)', r'require("\1.luau")', content)
    target = root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)
    written += 1
    print("wrote", rel)
print(written, "files")
```

Create this one file by hand (it cannot extract itself), then run `python3 tools/extract-plan.py docs/superpowers/plans/2026-09-27-pixel-shift.md --task <N>` for each task's files.

- [ ] **Step 2: Test framework and runner**

```lua
-- file: tests/testlib.luau
--!nonstrict
-- Minimal test framework for the standalone luau CLI.
local M = { tests = {} }

function M.test(name: string, fn: () -> ())
	table.insert(M.tests, { name = name, fn = fn })
end

local function fail(msg: string)
	error(msg, 3)
end

function M.eq(actual, expected, msg: string?)
	if actual ~= expected then
		fail(`{msg or "values differ"}: expected {tostring(expected)}, got {tostring(actual)}`)
	end
end

function M.near(actual: number, expected: number, tol: number?, msg: string?)
	local t = tol or 1e-6
	if type(actual) ~= "number" or math.abs(actual - expected) > t then
		fail(`{msg or "not near"}: expected {expected} ± {t}, got {tostring(actual)}`)
	end
end

function M.ok(value, msg: string?)
	if not value then
		fail(msg or "expected a truthy value")
	end
end

function M.run(filter: string?)
	local passed, failed = 0, 0
	for _, t in ipairs(M.tests) do
		if filter == nil or filter == "" or string.find(t.name, filter, 1, true) then
			local ok, err = pcall(t.fn)
			if ok then
				passed += 1
			else
				failed += 1
				print(`FAIL {t.name}\n     {tostring(err)}`)
			end
		end
	end
	print(`{passed} passed, {failed} failed`)
	if failed > 0 then
		error("test failures", 0)
	end
end

return M
```

```lua
-- file: tests/run.luau
--!nonstrict
local t = require("./testlib")
local filter = ...

local modules = {
	"./smoke_test",
}
for _, m in ipairs(modules) do
	require(m)
end

t.run(filter)
```

```lua
-- file: tests/smoke_test.luau
--!nonstrict
local t = require("./testlib")
local probe = require("../pixel-shift/core/probe")

t.test("smoke: require across directories", function()
	t.eq(probe.hello(), "probe")
end)

return {}
```

```bash
# -- file: tools/test.sh
#!/usr/bin/env bash
# Runs the luau unit tests. Usage: tools/test.sh [name-filter]
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
luau="${LUAU:-$root/.tools/bin/luau}"
command -v "$luau" >/dev/null 2>&1 || luau="luau"
cd "$root"
exec "$luau" -O2 tests/run.luau -a "${1:-}"
```

```lua
-- file: pixel-shift/core/probe.luau
--!nonstrict
-- Temporary: proves relative, extension-less require works in both runtimes.
return {
	hello = function()
		return "probe"
	end,
}
```

- [ ] **Step 3: Run the smoke test**

Run: `chmod +x tools/*.sh tools/*.py && tools/test.sh`
Expected: `1 passed, 0 failed`

- [ ] **Step 4: Manifest, translations, stub entries**

```toml
# -- file: pixel-shift/plugin.toml
id = "mgeldi/pixel-shift"
name = "Pixel Shift"
version = "0.1.0"
plugin_api = 32
author = "mgeldi"
license = "MIT"
dependencies = ["grim"]
tags = ["bar", "panel", "service", "shortcut", "utility", "hardware", "hyprland", "niri", "sway", "labwc", "mangowc"]
icon = "arrows-move-horizontal"
description = "Protects OLED screens from bar burn-in: measures your bar, simulates wear and shifts it smartly."

[[setting]]
key = "panel_profile"
type = "select"
label_key = "settings.panel_profile.label"
description_key = "settings.panel_profile.description"
default = "generic"
options = [
  { value = "generic", label_key = "settings.panel_profile.options.generic" },
  { value = "woled", label_key = "settings.panel_profile.options.woled" },
  { value = "qdoled", label_key = "settings.panel_profile.options.qdoled" },
]

[[setting]]
key = "sample_minutes"
type = "int"
label_key = "settings.sample_minutes.label"
description_key = "settings.sample_minutes.description"
default = 10
min = 2
max = 60

[[setting]]
key = "step_minutes"
type = "int"
label_key = "settings.step_minutes.label"
description_key = "settings.step_minutes.description"
default = 4
min = 1
max = 30

[[setting]]
key = "max_shift"
type = "int"
label_key = "settings.max_shift.label"
description_key = "settings.max_shift.description"
default = 16
min = 2
max = 32

# Invisible spacer. Place one at the start of the left section, one at the end
# of the right section and one on each side of the center section.
[[widget]]
id = "spacer"
entry = "spacer.luau"

[widget.actions]
middle = "none"

# Background engine: scans the bar, samples exposure, optimises and plays the
# shift strategy. Owns all state.
[[service]]
id = "engine"
entry = "engine.luau"

# Burn-in Lab. Open with: noctalia msg panel-toggle mgeldi/pixel-shift:lab
[[panel]]
id = "lab"
entry = "lab.luau"
width = 980
height = 740
placement = "floating"
position = "center"

# Control-center tile: pause / resume shifting.
[[shortcut]]
id = "toggle"
entry = "toggle.luau"
```

```json
// -- file: pixel-shift/translations/en.json
{
  "settings": {
    "panel_profile": {
      "label": "Panel type",
      "description": "Which OLED technology your screen uses. Changes how much each colour channel wears.",
      "options": {
        "generic": "Generic OLED (blue wears fastest)",
        "woled": "WOLED (LG panels)",
        "qdoled": "QD-OLED (Samsung panels)"
      }
    },
    "sample_minutes": {
      "label": "Sampling interval (minutes)",
      "description": "How often the bar is captured to learn what it shows over the day."
    },
    "step_minutes": {
      "label": "Step time (minutes)",
      "description": "Time between 1 px moves. Spacers use slightly different multiples so they never move in step."
    },
    "max_shift": {
      "label": "Maximum shift (px)",
      "description": "Upper limit for how far any group may move."
    }
  }
}
```

The JSON block's `// -- file:` marker line is not valid JSON; the extractor drops the marker line, so the written file is valid JSON.

```lua
-- file: pixel-shift/spacer.luau
--!nonstrict
-- Spike stub (replaced in Task 17): width from shared state key "spike:w".
local width = noctalia.state.get("spike:w") or 0

local function render()
	barWidget.render(ui.box({ width = width, height = 1, fill = "#00000000" }))
end

noctalia.state.watch("spike:w", function(v)
	width = tonumber(v) or 0
	render()
end)

render()
```

```lua
-- file: pixel-shift/engine.luau
--!nonstrict
-- Spike stub (replaced in Task 19).
local probe = require("./core/probe")
noctalia.log("pixel-shift engine stub: " .. probe.hello())

function onIpc(event, payload)
	if event == "spike-width" then
		noctalia.state.set("spike:w", tonumber(payload) or 0)
	elseif event == "spike-state" then
		noctalia.state.set("spike:table", { a = 1, nested = { b = "x" }, list = { 1, 2, 3 } })
	elseif event == "spike-setting" then
		noctalia.log("pixel-shift margin_edge=" .. tostring(noctalia.getSetting("bar.main.margin_edge"))
			.. " thickness=" .. tostring(noctalia.getSetting("bar.main.thickness")))
	end
end
```

```lua
-- file: pixel-shift/lab.luau
--!nonstrict
-- Spike stub (replaced in Task 20): shows a BMP to test image reloads.
local path = nil

local function render()
	panel.render(ui.column({ gap = 8 }, {
		ui.label({ text = "Pixel Shift spike" }),
		ui.image({ path = path, width = 400, height = 60, fit = "stretch" }),
	}))
end

noctalia.state.watch("spike:img", function(v)
	path = v
	render()
end)

function onOpen()
	path = noctalia.state.get("spike:img")
	render()
end
```

```lua
-- file: pixel-shift/toggle.luau
--!nonstrict
-- Stub (replaced in Task 21).
shortcut.setLabel("Pixel Shift")
shortcut.setIcon("arrows-move-horizontal")
shortcut.setActive(true)
shortcut.setEnabled(true)
```

- [ ] **Step 5: Install locally and verify the require probe in Noctalia**

```bash
ln -sfn ~/Projects/noctalia-pixel-shift/pixel-shift ~/.config/noctalia/plugins/pixel-shift
noctalia msg config-reload
noctalia msg plugins enable mgeldi/pixel-shift
sleep 2; grep -n "pixel-shift" ~/.cache/noctalia/noctalia.log | tail -5
```

Expected: `pixel-shift engine stub: probe`. If instead the log shows a require error, change every `require("./x")` in `pixel-shift/` to `require("./x.luau")` and make `tests/` load modules through a shim `tests/req.luau` that strips `.luau`; record the decision in `docs/spikes.md`.

- [ ] **Step 6: CI workflow**

```yaml
# -- file: .github/workflows/test.yml
name: tests
on:
  push:
  pull_request:
jobs:
  luau:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install luau 0.740
        run: |
          curl -sSL -o luau.zip https://github.com/luau-lang/luau/releases/download/0.740/luau-ubuntu.zip
          mkdir -p .tools/bin && unzip -q luau.zip -d .tools/bin && chmod +x .tools/bin/*
      - name: Run tests
        run: tools/test.sh
```

- [ ] **Step 7: Commit**

```bash
git add tools tests pixel-shift .github .gitignore
git commit -m "chore: scaffold plugin, tests and tooling"
```

### Task 2: Spikes S1–S4 (throwaway, live)

**Files:**
- Create: `docs/spikes.md` (results and decisions)
- Modify (backup first): `~/.config/noctalia/20-bar.toml` (add spacer instances; they stay for real use)

- [ ] **Step 1: Place spacers in the live bar**

Back up `~/.config/noctalia/20-bar.toml` to `~/.config/noctalia-backups/<date>-pixel-shift/20-bar.toml`. Add instances and put them at the section edges:

```toml
[widget.ps_start]
type = "mgeldi/pixel-shift:spacer"

[widget.ps_center_l]
type = "mgeldi/pixel-shift:spacer"

[widget.ps_center_r]
type = "mgeldi/pixel-shift:spacer"

[widget.ps_end]
type = "mgeldi/pixel-shift:spacer"
```

`start = ["ps_start", ...]`, `center = ["ps_center_l", ..., "ps_center_r"]`, `end = [..., "ps_end"]`. Run `noctalia-check`.

- [ ] **Step 2: S1 spacer relayout and spacing**

```bash
grim -g "0,0 2560x42" /tmp/claude-1000/ps-s1-w0.png
noctalia msg plugin mgeldi/pixel-shift:engine all spike-width 8
sleep 0.3; grim -g "0,0 2560x42" /tmp/claude-1000/ps-s1-w8.png
noctalia msg plugin mgeldi/pixel-shift:engine all spike-width 0
```

Compare with a small Python diff (column cross-correlation per section). Record: start group shift (+8 expected), center shift (0 expected, both center spacers change together), end shift (−8 expected); whether a 0-width box still occupies `widget_spacing` (compare positions against a capture with the spacer removed from the list). Decision: if spacing applies, README tells users to drop one adjacent `gap`.

- [ ] **Step 3: S2 grim geometry and timing**

```bash
time grim -t ppm -g "0,0 2560x42" /tmp/claude-1000/ps-dp2.ppm
time grim -t ppm -g "2560,0 2560x40" /tmp/claude-1000/ps-dp3.ppm
head -c 20 /tmp/claude-1000/ps-dp3.ppm | head -2
```

Expected: DP-3 capture is `3840x60` (scale 1.5). Record capture time. Compare `noctalia.outputs()` values (log them from the engine stub via `spike-setting`) with `hyprctl monitors -j`.

- [ ] **Step 4: S3 ui.image reload + S6 state tables**

Write a BMP (any), `noctalia msg plugin mgeldi/pixel-shift:engine all spike-state`, set `spike:img` via a one-off IPC branch, open the lab (`noctalia msg panel-toggle mgeldi/pixel-shift:lab`), overwrite the BMP, set the same path again, screenshot the panel. Record whether the image updates, and whether a table set in state arrives intact in another entry.

- [ ] **Step 5: S4 vertical trick**

```bash
hyprctl clients -j > /tmp/claude-1000/ps-clients-before.json
printf '[bar.main]\nmargin_edge = 2\nthickness = 32\n' > ~/.config/noctalia/zz-pixel-shift.toml
noctalia msg config-reload
for i in 1 2 3 4 5 6; do grim -g "0,0 2560x42" /tmp/claude-1000/ps-s4-$i.png; sleep 0.05; done
hyprctl clients -j > /tmp/claude-1000/ps-clients-after.json
noctalia msg plugin mgeldi/pixel-shift:engine all spike-setting
rm ~/.config/noctalia/zz-pixel-shift.toml && noctalia msg config-reload
```

Record: window geometry unchanged? (compare `at`/`size`), any blank/partial bar frame during reload, `getSetting` shows the override (margin 2, thickness 32). Decision per spec §12 S4.

- [ ] **Step 6: Write `docs/spikes.md` and commit**

Results table (S1–S6 with numbers, S5 = 57 ms interpreted / 16 ms codegen for a full 2560×42 risk map) and the decisions taken. Remove `pixel-shift/core/probe.luau` and `tests/smoke_test.luau` from the runner once Task 3 adds real tests.

```bash
git add docs/spikes.md
git commit -m "docs: spike results"
```

---

### Task 3: `core/image` — f32 images and filters

**Files:**
- Create: `pixel-shift/core/image.luau`
- Test: `tests/image_test.luau` (add `"./image_test"` to `tests/run.luau`)

**Interfaces:**
- Produces: `type Image = {w, h, data: buffer}`, `type LinearRGB = {w, h, r, g, b: Image}`; `new(w,h)`, `get(img,x,y)`, `set(img,x,y,v)`, `copy(img)`, `crop(img,x0,x1,mode?)` (`"zero"` default | `"clamp"`), `maskColumns(img,x0,x1)`, `add(dst,src,scale?)`, `square(img)`, `hbox(src,dst,r)`, `vbox(src,dst,r)`, `gauss3(src,r)`, `dirBoxH(src,range,dir)`, `dirBoxV(src,range,dir)`, `shiftColumns(img,x0,x1,dx)`, `shiftRows(img,dy)`, `percentile(img,q,y0?,y1?)`, `rgbNew(w,h)`, `rgbMap(lin, fn)`, `luma(lin)`.

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/image_test.luau
--!nonstrict
local t = require("./testlib")
local image = require("../pixel-shift/core/image")

local function row(values)
	local img = image.new(#values, 1)
	for i, v in ipairs(values) do
		image.set(img, i - 1, 0, v)
	end
	return img
end

local function values(img, y)
	local out = {}
	for x = 0, img.w - 1 do
		out[x + 1] = image.get(img, x, y or 0)
	end
	return out
end

t.test("image: set/get round trip", function()
	local img = image.new(3, 2)
	image.set(img, 2, 1, 0.25)
	t.near(image.get(img, 2, 1), 0.25)
	t.near(image.get(img, 0, 0), 0)
end)

t.test("image: crop zero and clamp modes", function()
	local img = row({ 1, 2, 3 })
	local z = values(image.crop(img, -1, 4))
	t.near(z[1], 0); t.near(z[2], 1); t.near(z[4], 3); t.near(z[5], 0)
	local c = values(image.crop(img, -2, 5, "clamp"))
	t.near(c[1], 1); t.near(c[2], 1); t.near(c[3], 1); t.near(c[6], 3); t.near(c[7], 3)
end)

t.test("image: maskColumns keeps only the range", function()
	local v = values(image.maskColumns(row({ 1, 2, 3, 4 }), 1, 3))
	t.near(v[1], 0); t.near(v[2], 2); t.near(v[3], 3); t.near(v[4], 0)
end)

t.test("image: dirBoxH spreads right and left", function()
	local src = row({ 0, 0, 0, 0, 0, 3, 0, 0, 0, 0 })
	local r = values(image.dirBoxH(src, 2, 1))
	t.near(r[6], 1); t.near(r[7], 1); t.near(r[8], 1); t.near(r[9], 0); t.near(r[5], 0)
	local l = values(image.dirBoxH(src, 2, -1))
	t.near(l[4], 1); t.near(l[5], 1); t.near(l[6], 1); t.near(l[3], 0); t.near(l[7], 0)
	local same = values(image.dirBoxH(src, 0, 1))
	t.near(same[6], 3)
end)

t.test("image: dirBoxV spreads down", function()
	local img = image.new(1, 5)
	image.set(img, 0, 1, 2)
	local v = image.dirBoxV(img, 1, 1)
	t.near(image.get(v, 0, 1), 1); t.near(image.get(v, 0, 2), 1); t.near(image.get(v, 0, 3), 0)
end)

t.test("image: gauss3 keeps constants and mass", function()
	local c = image.new(20, 20)
	for y = 0, 19 do for x = 0, 19 do image.set(c, x, y, 0.7) end end
	local g = image.gauss3(c, 3)
	t.near(image.get(g, 0, 0), 0.7, 1e-5); t.near(image.get(g, 10, 10), 0.7, 1e-5)
	local imp = image.new(41, 41)
	image.set(imp, 20, 20, 1)
	local gi = image.gauss3(imp, 2)
	local sum = 0
	for y = 0, 40 do for x = 0, 40 do sum += image.get(gi, x, y) end end
	t.near(sum, 1, 1e-4)
	t.near(image.get(gi, 20, 20), (19 / 125) ^ 2, 1e-5)
end)

t.test("image: shiftColumns and shiftRows read from the offset", function()
	local s = values(image.shiftColumns(row({ 1, 2, 3, 4, 5 }), 1, 4, 1))
	t.near(s[1], 1); t.near(s[2], 3); t.near(s[3], 4); t.near(s[4], 5); t.near(s[5], 5)
	local img = image.new(1, 3)
	image.set(img, 0, 0, 1); image.set(img, 0, 1, 2); image.set(img, 0, 2, 3)
	local r = image.shiftRows(img, 1)
	t.near(image.get(r, 0, 0), 2); t.near(image.get(r, 0, 1), 3); t.near(image.get(r, 0, 2), 3)
end)

t.test("image: add, square, percentile, luma", function()
	local a = row({ 1, 2 })
	image.add(a, row({ 1, 1 }), 2)
	t.near(image.get(a, 1, 0), 4)
	t.near(image.get(image.square(a), 1, 0), 16)
	local p = image.new(100, 1)
	for x = 0, 99 do image.set(p, x, 0, x) end
	t.near(image.percentile(p, 0.5), 49.5, 0.2)
	local lin = image.rgbNew(1, 1)
	image.set(lin.r, 0, 0, 1)
	t.near(image.get(image.luma(lin), 0, 0), 0.2126, 1e-6)
end)

return {}
```

Expected value for the impulse centre: three passes of a 5-wide box give a 1-D centre weight of 19/125, so the 2-D centre is (19/125)².

- [ ] **Step 2: Run to verify failure**

Run: `tools/test.sh image`
Expected: FAIL (`could not resolve child component "image"`).

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/image.luau
--!nonstrict
-- Single-channel f32 images (row-major) and the O(pixels) filters the wear
-- model needs. LinearRGB bundles three channels in linear light.

export type Image = { w: number, h: number, data: buffer }
export type LinearRGB = { w: number, h: number, r: Image, g: Image, b: Image }

local rf, wf = buffer.readf32, buffer.writef32

local M = {}

function M.new(w: number, h: number): Image
	return { w = w, h = h, data = buffer.create(w * h * 4) }
end

function M.get(img: Image, x: number, y: number): number
	return rf(img.data, (y * img.w + x) * 4)
end

function M.set(img: Image, x: number, y: number, v: number)
	wf(img.data, (y * img.w + x) * 4, v)
end

function M.copy(img: Image): Image
	local out = M.new(img.w, img.h)
	buffer.copy(out.data, 0, img.data)
	return out
end

-- Columns [x0, x1) as a new image. Outside columns read as 0 ("zero") or as
-- the nearest edge column ("clamp").
function M.crop(img: Image, x0: number, x1: number, mode: string?): Image
	local w = x1 - x0
	local out = M.new(w, img.h)
	local a, b = math.max(x0, 0), math.min(x1, img.w)
	for y = 0, img.h - 1 do
		if b > a then
			buffer.copy(out.data, (y * w + a - x0) * 4, img.data, (y * img.w + a) * 4, (b - a) * 4)
		end
		if mode == "clamp" then
			local left = rf(img.data, (y * img.w) * 4)
			local right = rf(img.data, (y * img.w + img.w - 1) * 4)
			for x = 0, math.min(a - x0, w) - 1 do
				wf(out.data, (y * w + x) * 4, left)
			end
			for x = math.max(b - x0, 0), w - 1 do
				wf(out.data, (y * w + x) * 4, right)
			end
		end
	end
	return out
end

-- Copy with every column outside [x0, x1) set to 0.
function M.maskColumns(img: Image, x0: number, x1: number): Image
	local out = M.new(img.w, img.h)
	local a, b = math.max(x0, 0), math.min(x1, img.w)
	if b > a then
		for y = 0, img.h - 1 do
			local o = (y * img.w + a) * 4
			buffer.copy(out.data, o, img.data, o, (b - a) * 4)
		end
	end
	return out
end

-- dst += src * scale
function M.add(dst: Image, src: Image, scale: number?)
	local s = scale or 1
	local d, sd = dst.data, src.data
	for o = 0, (dst.w * dst.h - 1) * 4, 4 do
		wf(d, o, rf(d, o) + rf(sd, o) * s)
	end
end

function M.square(img: Image): Image
	local out = M.new(img.w, img.h)
	local s, d = img.data, out.data
	for o = 0, (img.w * img.h - 1) * 4, 4 do
		local v = rf(s, o)
		wf(d, o, v * v)
	end
	return out
end

-- Centred box of radius r with replicated edges.
function M.hbox(src: Image, dst: Image, r: number)
	local w, h = src.w, src.h
	local s, d = src.data, dst.data
	local inv = 1 / (2 * r + 1)
	for y = 0, h - 1 do
		local row = y * w
		local acc = 0
		for k = -r, r do
			local x = if k < 0 then 0 elseif k >= w then w - 1 else k
			acc += rf(s, (row + x) * 4)
		end
		for x = 0, w - 1 do
			wf(d, (row + x) * 4, acc * inv)
			local xo = x - r
			if xo < 0 then
				xo = 0
			end
			local xi = x + r + 1
			if xi >= w then
				xi = w - 1
			end
			acc += rf(s, (row + xi) * 4) - rf(s, (row + xo) * 4)
		end
	end
end

function M.vbox(src: Image, dst: Image, r: number)
	local w, h = src.w, src.h
	local s, d = src.data, dst.data
	local inv = 1 / (2 * r + 1)
	for x = 0, w - 1 do
		local acc = 0
		for k = -r, r do
			local y = if k < 0 then 0 elseif k >= h then h - 1 else k
			acc += rf(s, (y * w + x) * 4)
		end
		for y = 0, h - 1 do
			wf(d, (y * w + x) * 4, acc * inv)
			local yo = y - r
			if yo < 0 then
				yo = 0
			end
			local yi = y + r + 1
			if yi >= h then
				yi = h - 1
			end
			acc += rf(s, (yi * w + x) * 4) - rf(s, (yo * w + x) * 4)
		end
	end
end

-- Gaussian approximation: three passes of a (2r+1) box in each direction.
function M.gauss3(src: Image, r: number): Image
	local a, b = M.new(src.w, src.h), M.new(src.w, src.h)
	M.hbox(src, a, r)
	M.vbox(a, b, r)
	M.hbox(b, a, r)
	M.vbox(a, b, r)
	M.hbox(b, a, r)
	M.vbox(a, b, r)
	return b
end

-- Mean of src over offsets 0..range in direction dir: dir = +1 means content
-- moved right, so out(x) averages src(x - o). Zero outside the image.
function M.dirBoxH(src: Image, range: number, dir: number): Image
	if range <= 0 then
		return M.copy(src)
	end
	local out = M.new(src.w, src.h)
	local w, h = src.w, src.h
	local s, d = src.data, out.data
	local inv = 1 / (range + 1)
	for y = 0, h - 1 do
		local row = y * w
		local acc = 0
		if dir >= 0 then
			for x = 0, w - 1 do
				acc += rf(s, (row + x) * 4)
				local xo = x - range - 1
				if xo >= 0 then
					acc -= rf(s, (row + xo) * 4)
				end
				wf(d, (row + x) * 4, acc * inv)
			end
		else
			for x = w - 1, 0, -1 do
				acc += rf(s, (row + x) * 4)
				local xo = x + range + 1
				if xo < w then
					acc -= rf(s, (row + xo) * 4)
				end
				wf(d, (row + x) * 4, acc * inv)
			end
		end
	end
	return out
end

-- Vertical counterpart of dirBoxH: dir = +1 means content moved down.
function M.dirBoxV(src: Image, range: number, dir: number): Image
	if range <= 0 then
		return M.copy(src)
	end
	local out = M.new(src.w, src.h)
	local w, h = src.w, src.h
	local s, d = src.data, out.data
	local inv = 1 / (range + 1)
	for x = 0, w - 1 do
		local acc = 0
		if dir >= 0 then
			for y = 0, h - 1 do
				acc += rf(s, (y * w + x) * 4)
				local yo = y - range - 1
				if yo >= 0 then
					acc -= rf(s, (yo * w + x) * 4)
				end
				wf(d, (y * w + x) * 4, acc * inv)
			end
		else
			for y = h - 1, 0, -1 do
				acc += rf(s, (y * w + x) * 4)
				local yo = y + range + 1
				if yo < h then
					acc -= rf(s, (yo * w + x) * 4)
				end
				wf(d, (y * w + x) * 4, acc * inv)
			end
		end
	end
	return out
end

-- Copy where columns [x0, x1) read from x + dx (clamped to the image).
function M.shiftColumns(img: Image, x0: number, x1: number, dx: number): Image
	local out = M.copy(img)
	if dx == 0 then
		return out
	end
	local w = img.w
	for y = 0, img.h - 1 do
		for x = math.max(x0, 0), math.min(x1, w) - 1 do
			local sx = x + dx
			if sx < 0 then
				sx = 0
			elseif sx >= w then
				sx = w - 1
			end
			wf(out.data, (y * w + x) * 4, rf(img.data, (y * w + sx) * 4))
		end
	end
	return out
end

-- Copy where every row y reads from y + dy (clamped).
function M.shiftRows(img: Image, dy: number): Image
	local out = M.new(img.w, img.h)
	local w, h = img.w, img.h
	for y = 0, h - 1 do
		local sy = y + dy
		if sy < 0 then
			sy = 0
		elseif sy >= h then
			sy = h - 1
		end
		buffer.copy(out.data, y * w * 4, img.data, sy * w * 4, w * 4)
	end
	return out
end

-- q-quantile (0..1) of the rows [y0, y1), via a 4096-bin histogram.
function M.percentile(img: Image, q: number, y0: number?, y1: number?): number
	local a, b = y0 or 0, y1 or img.h
	local lo, hi = math.huge, -math.huge
	for y = a, b - 1 do
		for x = 0, img.w - 1 do
			local v = rf(img.data, (y * img.w + x) * 4)
			if v < lo then
				lo = v
			end
			if v > hi then
				hi = v
			end
		end
	end
	if hi <= lo then
		return lo
	end
	local bins = 4096
	local counts = table.create(bins, 0)
	local scale = bins / (hi - lo)
	local n = 0
	for y = a, b - 1 do
		for x = 0, img.w - 1 do
			local i = math.floor((rf(img.data, (y * img.w + x) * 4) - lo) * scale)
			if i >= bins then
				i = bins - 1
			end
			counts[i + 1] += 1
			n += 1
		end
	end
	local target = q * n
	local acc = 0
	for i = 1, bins do
		acc += counts[i]
		if acc >= target then
			return lo + (i - 0.5) / scale
		end
	end
	return hi
end

function M.rgbNew(w: number, h: number): LinearRGB
	return { w = w, h = h, r = M.new(w, h), g = M.new(w, h), b = M.new(w, h) }
end

function M.rgbMap(lin: LinearRGB, fn: (Image) -> Image): LinearRGB
	local r, g, b = fn(lin.r), fn(lin.g), fn(lin.b)
	return { w = r.w, h = r.h, r = r, g = g, b = b }
end

function M.luma(lin: LinearRGB): Image
	local out = M.new(lin.w, lin.h)
	local r, g, b, d = lin.r.data, lin.g.data, lin.b.data, out.data
	for o = 0, (lin.w * lin.h - 1) * 4, 4 do
		wf(d, o, 0.2126 * rf(r, o) + 0.7152 * rf(g, o) + 0.0722 * rf(b, o))
	end
	return out
end

return M
```

- [ ] **Step 4: Run to verify pass**

Run: `tools/test.sh image`
Expected: `8 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/image.luau tests/image_test.luau tests/run.luau
git commit -m "feat(core): f32 image type and box filters"
```

### Task 4: `core/color` — colour spaces and theme ramps

**Files:**
- Create: `pixel-shift/core/color.luau`
- Test: `tests/color_test.luau`

**Interfaces:**
- Produces: `toLinear8(v)`, `toLinear(c)`, `fromLinear(l)`, `to8(c)`, `hexToRgb(hex) -> r,g,b | nil`, `hexToOklch(hex) -> L,C,h | nil`, `oklchToSrgb(L,C,h) -> r,g,b`, `glowRamp(hex) -> {{r8,g8,b8}} (256)`, `riskRamp(hex)`, `FALLBACK_PRIMARY`.

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/color_test.luau
--!nonstrict
local t = require("./testlib")
local color = require("../pixel-shift/core/color")

local function near8(c, r, g, b)
	t.near(c[1], r, 3, "red"); t.near(c[2], g, 3, "green"); t.near(c[3], b, 3, "blue")
end

t.test("color: sRGB transfer", function()
	t.near(color.toLinear8(0), 0); t.near(color.toLinear8(255), 1)
	t.near(color.toLinear8(128), 0.2158605, 1e-6)
	t.near(color.fromLinear(color.toLinear(0.5)), 0.5, 1e-9)
	t.eq(color.to8(1.2), 255); t.eq(color.to8(-1), 0)
end)

t.test("color: hex parsing and OKLCH", function()
	local r, g, b = color.hexToRgb("#ff8000")
	t.near(r, 1); t.near(g, 128 / 255); t.near(b, 0)
	t.eq(color.hexToRgb("nope"), nil)
	local L, C = color.hexToOklch("#ffffff")
	t.near(L, 1, 1e-3); t.near(C, 0, 1e-3)
end)

t.test("color: glow ramp matches the approved prototype", function()
	-- index 201 = t 200/255 (prototype hi[200])
	near8(color.glowRamp("#c1c5de")[201], 175, 185, 254)
	near8(color.glowRamp("#b58fff")[201], 213, 155, 254)
	near8(color.glowRamp("#8B2E2E")[201], 254, 131, 127)
end)

t.test("color: ramps rise in lightness and survive bad input", function()
	local ramp = color.glowRamp(nil)
	t.eq(#ramp, 256)
	local function lum(c) return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3] end
	t.ok(lum(ramp[1]) < lum(ramp[128]) and lum(ramp[128]) < lum(ramp[256]))
	local risk = color.riskRamp("#c1c5de")
	t.ok(lum(risk[1]) < lum(risk[256]))
end)

return {}
```

- [ ] **Step 2: Run to verify failure**

Run: `tools/test.sh color` → FAIL (module missing).

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/color.luau
--!nonstrict
-- sRGB <-> linear light, OKLab/OKLCH, and the theme-derived colour ramps.

local M = {}

M.FALLBACK_PRIMARY = "#8ab4f8"

local TO_LINEAR = table.create(256, 0)
for i = 0, 255 do
	local c = i / 255
	TO_LINEAR[i + 1] = if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
end

function M.toLinear8(v: number): number
	return TO_LINEAR[v + 1]
end

function M.toLinear(c: number): number
	return if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
end

function M.fromLinear(l: number): number
	if l <= 0 then
		return 0
	elseif l >= 1 then
		return 1
	end
	return if l <= 0.0031308 then 12.92 * l else 1.055 * l ^ (1 / 2.4) - 0.055
end

function M.to8(c: number): number
	local v = math.floor(c * 255 + 0.5)
	return if v < 0 then 0 elseif v > 255 then 255 else v
end

function M.hexToRgb(hex: string?): (number?, number?, number?)
	if type(hex) ~= "string" then
		return nil
	end
	local r, g, b = string.match(hex, "^#(%x%x)(%x%x)(%x%x)")
	if not r then
		return nil
	end
	return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
end

local function linearToOklab(r, g, b)
	local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
	local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
	local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
	return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end

local function oklabToLinear(L, a, b)
	local l_ = L + 0.3963377774 * a + 0.2158037573 * b
	local m_ = L - 0.1055613458 * a - 0.0638541728 * b
	local s_ = L - 0.0894841775 * a - 1.2914855480 * b
	local l, m, s = l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_
	return 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
end

function M.hexToOklch(hex: string?): (number?, number?, number?)
	local r, g, b = M.hexToRgb(hex)
	if not r then
		return nil
	end
	local L, a, bb = linearToOklab(M.toLinear(r), M.toLinear(g), M.toLinear(b))
	return L, math.sqrt(a * a + bb * bb), math.deg(math.atan2(bb, a)) % 360
end

-- sRGB 0..1, gamut-clipped per channel in linear light.
function M.oklchToSrgb(L: number, C: number, h: number): (number, number, number)
	local rad = math.rad(h)
	local r, g, b = oklabToLinear(L, C * math.cos(rad), C * math.sin(rad))
	return M.fromLinear(r), M.fromLinear(g), M.fromLinear(b)
end

local function clamp(x, a, b)
	return if x < a then a elseif x > b then b else x
end

-- 256-step ramp in the primary's hue; lightness rises L0 -> L1.
local function ramp(hex, L0, L1, chroma)
	local _, C, h = M.hexToOklch(hex)
	if not C then
		_, C, h = M.hexToOklch(M.FALLBACK_PRIMARY)
	end
	local out = table.create(256)
	for i = 0, 255 do
		local t = i / 255
		local r, g, b = M.oklchToSrgb(L0 + (L1 - L0) * t, chroma(C, t), h)
		out[i + 1] = { M.to8(r), M.to8(g), M.to8(b) }
	end
	return out
end

-- Hotspot glow (spec 5.3): theme hue, chroma boosted so near-grey and dark
-- primaries still glow bright and coloured.
function M.glowRamp(hex: string?)
	return ramp(hex, 0.50, 0.90, function(C)
		return clamp(math.max(1.6 * C, 0.13), 0.13, 0.22)
	end)
end

-- Risk view ramp: dark to bright in the theme hue.
function M.riskRamp(hex: string?)
	return ramp(hex, 0.24, 0.95, function(C, t)
		return clamp(C, 0.07, 0.19) * (0.55 + 0.45 * math.sin(math.pi * t * 0.9))
	end)
end

return M
```

- [ ] **Step 4: Run to verify pass**

Run: `tools/test.sh color` → `4 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/color.luau tests/color_test.luau tests/run.luau
git commit -m "feat(core): colour spaces and theme glow ramps"
```

### Task 5: `core/ppm` and `core/bmp` — raster IO

**Files:**
- Create: `pixel-shift/core/ppm.luau`, `pixel-shift/core/bmp.luau`
- Test: `tests/raster_test.luau`

**Interfaces:**
- Produces: `ppm.Rgb8 = {w, h, data}` (3 bytes/px); `ppm.new(w,h)`, `ppm.get(img,x,y) -> r,g,b`, `ppm.set(img,x,y,r,g,b)`, `ppm.parse(s) -> Rgb8? , err?`, `ppm.transpose(img)`, `ppm.blank(img, x0, x1, y0, y1)` (fills with the row's edge colour, used to blank titles in public screenshots), `bmp.encode(img: Rgb8) -> string`.

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/raster_test.luau
--!nonstrict
local t = require("./testlib")
local ppm = require("../pixel-shift/core/ppm")
local bmp = require("../pixel-shift/core/bmp")

local function bytes(...)
	local parts = {}
	for _, v in ipairs({ ... }) do
		table.insert(parts, string.char(v))
	end
	return table.concat(parts)
end

t.test("ppm: parses P6 with comments", function()
	local img = assert(ppm.parse("P6\n# grim\n2 1\n255\n" .. bytes(255, 0, 0, 0, 255, 7)))
	t.eq(img.w, 2); t.eq(img.h, 1)
	local r, g, b = ppm.get(img, 1, 0)
	t.eq(r, 0); t.eq(g, 255); t.eq(b, 7)
end)

t.test("ppm: rejects bad input", function()
	t.eq(ppm.parse("P5\n1 1\n255\n\0"), nil)
	t.eq(ppm.parse("P6\n2 2\n255\n" .. bytes(1, 2, 3)), nil)
	t.eq(ppm.parse("P6\n1 1\n65535\n" .. bytes(0, 0, 0, 0, 0, 0)), nil)
	t.eq(ppm.parse(nil), nil)
end)

t.test("ppm: transpose swaps axes", function()
	local img = ppm.new(2, 1)
	ppm.set(img, 0, 0, 1, 2, 3); ppm.set(img, 1, 0, 4, 5, 6)
	local tr = ppm.transpose(img)
	t.eq(tr.w, 1); t.eq(tr.h, 2)
	local r = ppm.get(tr, 0, 1)
	t.eq(r, 4)
end)

t.test("bmp: header, padding, bottom-up BGR", function()
	local img = ppm.new(2, 2)
	ppm.set(img, 0, 0, 10, 20, 30) -- top-left
	ppm.set(img, 0, 1, 40, 50, 60) -- bottom-left
	local s = bmp.encode(img)
	t.eq(#s, 54 + 2 * 8)
	t.eq(string.sub(s, 1, 2), "BM")
	t.eq(string.unpack("<i4", s, 19), 2)
	t.eq(string.unpack("<i4", s, 23), 2)
	-- first stored row is the bottom row: B,G,R of (0,1)
	t.eq(string.byte(s, 55), 60); t.eq(string.byte(s, 56), 50); t.eq(string.byte(s, 57), 40)
	-- second stored row starts after 8 bytes: (0,0)
	t.eq(string.byte(s, 63), 30)
end)

t.test("ppm: blank fills a region from its left edge colour", function()
	local img = ppm.new(4, 1)
	ppm.set(img, 0, 0, 9, 9, 9); ppm.set(img, 1, 0, 200, 200, 200); ppm.set(img, 2, 0, 200, 200, 200)
	ppm.blank(img, 1, 3, 0, 1)
	local r = ppm.get(img, 2, 0)
	t.eq(r, 9)
end)

return {}
```

- [ ] **Step 2: Run to verify failure** — `tools/test.sh raster` → FAIL.

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/ppm.luau
--!nonstrict
-- 8-bit RGB rasters and the binary PPM (P6) reader used for grim captures.

export type Rgb8 = { w: number, h: number, data: buffer }

local ru8, wu8 = buffer.readu8, buffer.writeu8

local M = {}

function M.new(w: number, h: number): Rgb8
	return { w = w, h = h, data = buffer.create(w * h * 3) }
end

function M.get(img: Rgb8, x: number, y: number): (number, number, number)
	local o = (y * img.w + x) * 3
	return ru8(img.data, o), ru8(img.data, o + 1), ru8(img.data, o + 2)
end

function M.set(img: Rgb8, x: number, y: number, r: number, g: number, b: number)
	local o = (y * img.w + x) * 3
	wu8(img.data, o, r)
	wu8(img.data, o + 1, g)
	wu8(img.data, o + 2, b)
end

local function isSpace(c)
	return c == 32 or c == 9 or c == 10 or c == 13
end

function M.parse(s: string?): (Rgb8?, string?)
	if type(s) ~= "string" or string.sub(s, 1, 2) ~= "P6" then
		return nil, "not a P6 PPM"
	end
	local n = #s
	local pos = 3
	local fields = {}
	while #fields < 3 do
		while pos <= n do
			local c = string.byte(s, pos)
			if isSpace(c) then
				pos += 1
			elseif c == 35 then
				while pos <= n and string.byte(s, pos) ~= 10 do
					pos += 1
				end
			else
				break
			end
		end
		local start = pos
		while pos <= n do
			local c = string.byte(s, pos)
			if c < 48 or c > 57 then
				break
			end
			pos += 1
		end
		if pos == start then
			return nil, "bad header"
		end
		table.insert(fields, tonumber(string.sub(s, start, pos - 1)))
	end
	if pos > n or not isSpace(string.byte(s, pos)) then
		return nil, "bad header"
	end
	pos += 1
	local w, h, maxval = fields[1], fields[2], fields[3]
	if maxval ~= 255 then
		return nil, "unsupported maxval"
	end
	if w <= 0 or h <= 0 then
		return nil, "bad size"
	end
	local need = w * h * 3
	if n - pos + 1 < need then
		return nil, "truncated"
	end
	local img = M.new(w, h)
	buffer.copy(img.data, 0, buffer.fromstring(s), pos - 1, need)
	return img
end

function M.transpose(img: Rgb8): Rgb8
	local out = M.new(img.h, img.w)
	for y = 0, img.h - 1 do
		for x = 0, img.w - 1 do
			buffer.copy(out.data, (x * out.w + y) * 3, img.data, (y * img.w + x) * 3, 3)
		end
	end
	return out
end

-- Fill columns [x0, x1) of rows [y0, y1) with the colour just left of x0
-- (per row). Used to blank window/media titles in public screenshots.
function M.blank(img: Rgb8, x0: number, x1: number, y0: number, y1: number)
	for y = y0, y1 - 1 do
		local sx = math.max(x0 - 1, 0)
		local r, g, b = M.get(img, sx, y)
		for x = x0, x1 - 1 do
			M.set(img, x, y, r, g, b)
		end
	end
end

return M
```

```lua
-- file: pixel-shift/core/bmp.luau
--!nonstrict
-- 24-bit uncompressed BMP encoder (bottom-up rows, 4-byte row padding).

local M = {}

function M.encode(img): string
	local w, h = img.w, img.h
	local rowSize = (w * 3 + 3) // 4 * 4
	local size = 54 + rowSize * h
	local b = buffer.create(size)
	buffer.writeu8(b, 0, 66)
	buffer.writeu8(b, 1, 77)
	buffer.writeu32(b, 2, size)
	buffer.writeu32(b, 10, 54)
	buffer.writeu32(b, 14, 40)
	buffer.writei32(b, 18, w)
	buffer.writei32(b, 22, h)
	buffer.writeu16(b, 26, 1)
	buffer.writeu16(b, 28, 24)
	buffer.writeu32(b, 34, rowSize * h)
	buffer.writei32(b, 38, 2835)
	buffer.writei32(b, 42, 2835)
	local src = img.data
	for y = 0, h - 1 do
		local dst = 54 + (h - 1 - y) * rowSize
		for x = 0, w - 1 do
			local s = (y * w + x) * 3
			local d = dst + x * 3
			buffer.writeu8(b, d, buffer.readu8(src, s + 2))
			buffer.writeu8(b, d + 1, buffer.readu8(src, s + 1))
			buffer.writeu8(b, d + 2, buffer.readu8(src, s))
		end
	end
	return buffer.tostring(b)
end

return M
```

- [ ] **Step 4: Run to verify pass** — `tools/test.sh raster` → `5 passed`.

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/ppm.luau pixel-shift/core/bmp.luau tests/raster_test.luau tests/run.luau
git commit -m "feat(core): PPM reader and BMP writer"
```

### Task 6: `core/wear` — OLED wear model

**Files:**
- Create: `pixel-shift/core/wear.luau`
- Test: `tests/wear_test.luau`

**Interfaces:**
- Consumes: `image`, `color.toLinear8`, `ppm.Rgb8`.
- Produces: `N = 1.6`, `PROFILES`, `ORDER = {"generic","woled","qdoled"}`, `profile(name)`, `pixel(p, r, g, b)`, `white(p)`, `linearFromRgb8(rgb8) -> LinearRGB`, `map(p, lin) -> Image`.

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/wear_test.luau
--!nonstrict
local t = require("./testlib")
local wear = require("../pixel-shift/core/wear")
local ppm = require("../pixel-shift/core/ppm")
local image = require("../pixel-shift/core/image")

t.test("wear: profile whites", function()
	t.near(wear.white(wear.profile("generic")), 2.3, 1e-9)
	t.near(wear.white(wear.profile("qdoled")), 3.0, 1e-9)
	t.near(wear.white(wear.profile("woled")), 1.0, 1e-9)
	t.eq(wear.profile("nope"), wear.PROFILES.generic)
end)

t.test("wear: channel weights and exponent", function()
	t.near(wear.pixel(wear.PROFILES.generic, 0.5, 0, 0), 0.55 * 0.5 ^ 1.6, 1e-12)
	t.near(wear.pixel(wear.PROFILES.woled, 1, 0.5, 0.5), 1.0 * 0.5 ^ 1.6 + 0.5 * 0.5 ^ 1.6, 1e-12)
	t.near(wear.pixel(wear.PROFILES.generic, -0.1, 0, 0), 0)
end)

t.test("wear: map over a linear image from Rgb8", function()
	local img = ppm.new(2, 1)
	ppm.set(img, 0, 0, 255, 255, 255)
	local lin = wear.linearFromRgb8(img)
	local m = wear.map(wear.PROFILES.generic, lin)
	t.near(image.get(m, 0, 0), 2.3, 1e-5)
	t.near(image.get(m, 1, 0), 0)
end)

return {}
```

- [ ] **Step 2: Run to verify failure** — `tools/test.sh wear` → FAIL.

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/wear.luau
--!nonstrict
-- OLED wear model: wear rate per pixel = sum over channels of k_c * L_c^n,
-- n = 1.6 (luminance acceleration). WOLED routes min(R,G,B) through a white
-- subpixel. Values are relative; there is no absolute lifetime here.

local image = require("./image")
local color = require("./color")

local rf, wf = buffer.readf32, buffer.writef32

local M = {}

M.N = 1.6
M.PROFILES = {
	generic = { k = { 0.55, 0.75, 1.0 } },
	woled = { k = { 0.5, 0.6, 0.9 }, white = 1.0 },
	qdoled = { k = { 1.0, 1.0, 1.0 } },
}
M.ORDER = { "generic", "woled", "qdoled" }

function M.profile(name: string?)
	return M.PROFILES[name or "generic"] or M.PROFILES.generic
end

local function unit(v)
	return if v < 0 then 0 elseif v > 1 then 1 else v
end

function M.pixel(p, r: number, g: number, b: number): number
	local n = M.N
	r, g, b = unit(r), unit(g), unit(b)
	local k = p.k
	if p.white then
		local m = math.min(r, g, b)
		return p.white * m ^ n + k[1] * (r - m) ^ n + k[2] * (g - m) ^ n + k[3] * (b - m) ^ n
	end
	return k[1] * r ^ n + k[2] * g ^ n + k[3] * b ^ n
end

function M.white(p): number
	return M.pixel(p, 1, 1, 1)
end

function M.linearFromRgb8(img): image.LinearRGB
	local lin = image.rgbNew(img.w, img.h)
	local src = img.data
	local rd, gd, bd = lin.r.data, lin.g.data, lin.b.data
	for i = 0, img.w * img.h - 1 do
		local s, o = i * 3, i * 4
		wf(rd, o, color.toLinear8(buffer.readu8(src, s)))
		wf(gd, o, color.toLinear8(buffer.readu8(src, s + 1)))
		wf(bd, o, color.toLinear8(buffer.readu8(src, s + 2)))
	end
	return lin
end

function M.map(p, lin: image.LinearRGB): image.Image
	local out = image.new(lin.w, lin.h)
	local rd, gd, bd, d = lin.r.data, lin.g.data, lin.b.data, out.data
	for o = 0, (lin.w * lin.h - 1) * 4, 4 do
		wf(d, o, M.pixel(p, rf(rd, o), rf(gd, o), rf(bd, o)))
	end
	return out
end

return M
```

- [ ] **Step 4: Run to verify pass** — `tools/test.sh wear` → `3 passed`.

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/wear.luau tests/wear_test.luau tests/run.luau
git commit -m "feat(core): OLED wear profiles"
```

### Task 7: `core/risk` — risk map, reference, score

**Files:**
- Create: `pixel-shift/core/risk.luau`
- Test: `tests/risk_test.luau`

**Interfaces:**
- Consumes: `image.gauss3`, `wear.white`.
- Produces: `map(E) -> Image`, `reference(p) -> number`, `type Hist = {bins, n, cap}`, `BINS = 1024`, `newHist(cap)`, `accumulate(h, R, y0, y1, x0, x1)`, `merge(dst, src)`, `percentile(h, q)`, `score(h, rref)`.

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/risk_test.luau
--!nonstrict
local t = require("./testlib")
local risk = require("../pixel-shift/core/risk")
local image = require("../pixel-shift/core/image")
local wear = require("../pixel-shift/core/wear")

t.test("risk: flat exposure has no risk", function()
	local E = image.new(30, 20)
	for y = 0, 19 do for x = 0, 29 do image.set(E, x, y, 1.5) end end
	local R = risk.map(E)
	t.near(image.get(R, 15, 10), 0, 1e-5)
end)

t.test("risk: reference equals the analytic line response", function()
	-- centre weights of three-pass boxes: width 3 -> 7/27, width 21 -> 331/9261
	local expected = 2.3 * ((1 - 7 / 27) + 0.5 * (1 - 331 / 9261))
	t.near(risk.reference(wear.PROFILES.generic), expected, 1e-4)
end)

t.test("risk: histogram percentile and score", function()
	local R = image.new(100, 1)
	for x = 0, 99 do image.set(R, x, 0, x) end
	local h = risk.newHist(200)
	risk.accumulate(h, R, 0, 1, 0, 100)
	t.eq(h.n, 100)
	t.near(risk.percentile(h, 0.99), 98.6, 0.5)
	local flat = image.new(10, 1)
	for x = 0, 9 do image.set(flat, x, 0, 3) end
	local h2 = risk.newHist(6)
	risk.accumulate(h2, flat, 0, 1, 0, 10)
	t.near(risk.score(h2, 3), 100, 0.5)
	local h3 = risk.newHist(6)
	risk.accumulate(h3, flat, 0, 1, 0, 10)
	risk.merge(h2, h3)
	t.eq(h2.n, 20)
end)

return {}
```

- [ ] **Step 2: Run to verify failure** — `tools/test.sh risk` → FAIL.

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/risk.luau
--!nonstrict
-- Visible burn-in risk: wear that differs from its neighbourhood, at a fine
-- scale (strokes, icon edges) and a coarse scale (blocks, band edges).

local image = require("./image")
local wear = require("./wear")

local rf, wf = buffer.readf32, buffer.writef32

local M = {}

M.FINE_R = 1
M.COARSE_R = 10
M.COARSE_W = 0.5
M.BINS = 1024

export type Hist = { bins: { number }, n: number, cap: number }

function M.map(E: image.Image): image.Image
	local g1 = image.gauss3(E, M.FINE_R)
	local g2 = image.gauss3(E, M.COARSE_R)
	local R = image.new(E.w, E.h)
	local e, a, b, r = E.data, g1.data, g2.data, R.data
	local cw = M.COARSE_W
	for o = 0, (E.w * E.h - 1) * 4, 4 do
		local v = rf(e, o)
		wf(r, o, math.abs(v - rf(a, o)) + cw * math.abs(v - rf(b, o)))
	end
	return R
end

-- Risk of a 1 px pure-white line on black without shifting: the 100 mark.
function M.reference(p): number
	local w, h = 128, 42
	local E = image.new(w, h)
	local v = wear.white(p)
	for x = 0, w - 1 do
		image.set(E, x, 20, v)
	end
	return image.get(M.map(E), w // 2, 20)
end

function M.newHist(cap: number): Hist
	return { bins = table.create(M.BINS, 0), n = 0, cap = cap }
end

function M.accumulate(h: Hist, R: image.Image, y0: number, y1: number, x0: number, x1: number)
	local scale = M.BINS / h.cap
	local bins = h.bins
	local top = M.BINS - 1
	local a, b = math.max(x0, 0), math.min(x1, R.w)
	for y = math.max(y0, 0), math.min(y1, R.h) - 1 do
		local row = y * R.w
		for x = a, b - 1 do
			local i = math.floor(rf(R.data, (row + x) * 4) * scale)
			if i > top then
				i = top
			elseif i < 0 then
				i = 0
			end
			bins[i + 1] += 1
		end
		h.n += math.max(b - a, 0)
	end
end

function M.merge(dst: Hist, src: Hist)
	assert(dst.cap == src.cap, "histogram caps differ")
	local d, s = dst.bins, src.bins
	for i = 1, M.BINS do
		d[i] += s[i]
	end
	dst.n += src.n
end

function M.percentile(h: Hist, q: number): number
	if h.n == 0 then
		return 0
	end
	local target = q * h.n
	local acc = 0
	local width = h.cap / M.BINS
	for i = 1, M.BINS do
		acc += h.bins[i]
		if acc >= target then
			return (i - 0.5) * width
		end
	end
	return h.cap
end

function M.score(h: Hist, rref: number): number
	return 100 * M.percentile(h, 0.99) / rref
end

return M
```

- [ ] **Step 4: Run to verify pass** — `tools/test.sh risk` → `3 passed`.

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/risk.luau tests/risk_test.luau tests/run.luau
git commit -m "feat(core): risk map, reference and score"
```

### Task 8: `core/util` — pure helpers

**Files:**
- Create: `pixel-shift/core/util.luau`
- Test: `tests/util_test.luau`

**Interfaces:**
- Produces: `configDir(getenv) -> string`, `stableEncode(v)`, `fnv1a(s) -> "8 hex"`, `fingerprint(v)`, `randomId(entropy) -> "8 hex"`, `captureGeometry(out, bar, contextPx?) -> {geometry, transpose, flipped, barPx, vDir, scale}`, `rowLayout(flipped, rows, barPx) -> barRows, scoreRows`, `pruneRegistry(reg, now, stale) -> reg, changed`, `displacements(layout, offsets) -> {[gi]=px}`, `verticalToml(barName, margin, thickness) -> string`, `side(x, w) -> "left"|"center"|"right"`.

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/util_test.luau
--!nonstrict
local t = require("./testlib")
local util = require("../pixel-shift/core/util")

local function env(tbl)
	return function(k) return tbl[k] end
end

t.test("util: config dir precedence", function()
	t.eq(util.configDir(env({ NOCTALIA_CONFIG_HOME = "/n", XDG_CONFIG_HOME = "/x", HOME = "/h" })), "/n")
	t.eq(util.configDir(env({ XDG_CONFIG_HOME = "/x", HOME = "/h" })), "/x/noctalia")
	t.eq(util.configDir(env({ HOME = "/h" })), "/h/.config/noctalia")
end)

t.test("util: fnv1a and fingerprints", function()
	t.eq(util.fnv1a(""), "811c9dc5")
	t.eq(util.fnv1a("a"), "e40c292c")
	t.eq(util.fingerprint({ b = 1, a = { 2, 3 } }), util.fingerprint({ a = { 2, 3 }, b = 1 }))
	t.ok(util.fingerprint({ a = 1 }) ~= util.fingerprint({ a = 2 }))
	local id = util.randomId("x")
	t.eq(#id, 8)
	t.ok(util.randomId("x") ~= util.randomId("y"))
end)

t.test("util: capture geometry top, scale 1 and 1.5", function()
	local g = util.captureGeometry({ x = 0, y = 0, width = 2560, height = 1440, scale = 1 }, { position = "top", thickness = 34, margin = 0 })
	t.eq(g.geometry, "0,0 2560x42"); t.eq(g.barPx, 34); t.eq(g.flipped, false); t.eq(g.vDir, 1); t.eq(g.transpose, false)
	local h = util.captureGeometry({ x = 2560, y = 0, width = 2560, height = 1440, scale = 1.5 }, { position = "top", thickness = 34, margin = 0 })
	t.eq(h.geometry, "2560,0 2560x40"); t.eq(h.barPx, 51)
end)

t.test("util: capture geometry bottom, left, right", function()
	local out = { x = 0, y = 0, width = 2560, height = 1440, scale = 1 }
	local b = util.captureGeometry(out, { position = "bottom", thickness = 34, margin = 0 })
	t.eq(b.geometry, "0,1398 2560x42"); t.eq(b.flipped, true); t.eq(b.vDir, -1)
	local l = util.captureGeometry(out, { position = "left", thickness = 34, margin = 4 })
	t.eq(l.geometry, "4,0 42x1440"); t.eq(l.transpose, true); t.eq(l.flipped, false)
	local r = util.captureGeometry(out, { position = "right", thickness = 34, margin = 0 })
	t.eq(r.geometry, "2518,0 42x1440"); t.eq(r.transpose, true); t.eq(r.flipped, true)
end)

t.test("util: row layout", function()
	local bar, score = util.rowLayout(false, 42, 34)
	t.eq(bar[1], 0); t.eq(bar[2], 34); t.eq(score[1], 0); t.eq(score[2], 36)
	bar, score = util.rowLayout(true, 42, 34)
	t.eq(bar[1], 8); t.eq(bar[2], 42); t.eq(score[1], 6); t.eq(score[2], 42)
end)

t.test("util: registry pruning", function()
	local reg, changed = util.pruneRegistry({ a = { t = 100 }, b = { t = 10 } }, 150, 90)
	t.ok(reg.a ~= nil); t.eq(reg.b, nil); t.eq(changed, true)
	local _, same = util.pruneRegistry({ a = { t = 100 } }, 150, 90)
	t.eq(same, false)
end)

t.test("util: displacements and misc", function()
	local layout = { groups = { { factors = { a = 1 } }, { factors = { a = 0.5, b = -0.5 } } } }
	local d = util.displacements(layout, { a = 4, b = 2 })
	t.eq(d[1], 4); t.eq(d[2], 1)
	local toml = util.verticalToml("main", 2, 32)
	t.ok(string.find(toml, "[bar.main]", 1, true) ~= nil)
	t.ok(string.find(toml, "margin_edge = 2", 1, true) ~= nil)
	t.ok(string.find(toml, "thickness = 32", 1, true) ~= nil)
	t.eq(util.side(100, 2560), "left"); t.eq(util.side(1280, 2560), "center"); t.eq(util.side(2400, 2560), "right")
end)

return {}
```

- [ ] **Step 2: Run to verify failure** — `tools/test.sh util` → FAIL.

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/util.luau
--!nonstrict
-- Small pure helpers shared by the entries: config paths, fingerprints,
-- capture geometry, registry upkeep. No Noctalia globals.

local M = {}

function M.configDir(getenv: (string) -> string?): string
	local dir = getenv("NOCTALIA_CONFIG_HOME")
	if dir and dir ~= "" then
		return dir
	end
	local xdg = getenv("XDG_CONFIG_HOME")
	if xdg and xdg ~= "" then
		return xdg .. "/noctalia"
	end
	return (getenv("HOME") or "~") .. "/.config/noctalia"
end

-- Stable text form of a value (sorted keys) for hashing.
function M.stableEncode(v): string
	if type(v) == "table" then
		local keys = {}
		for k in pairs(v) do
			table.insert(keys, k)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		local parts = table.create(#keys)
		for _, k in ipairs(keys) do
			table.insert(parts, tostring(k) .. "=" .. M.stableEncode(v[k]))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return tostring(v)
end

-- 32-bit FNV-1a. 16777619 = 2^24 + 403 keeps every product exact in a double.
function M.fnv1a(s: string): string
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		h = (h * 403 + bit32.lshift(h, 24)) % 4294967296
	end
	return string.format("%08x", h)
end

function M.fingerprint(v): string
	return M.fnv1a(M.stableEncode(v))
end

local counter = 0
function M.randomId(entropy: string): string
	counter += 1
	return M.fnv1a(entropy .. "|" .. tostring(counter) .. "|" .. tostring(os.clock()))
end

-- Output (logical px) + bar settings -> grim geometry and orientation.
-- The capture covers the bar plus `contextPx` physical px on its inner side.
function M.captureGeometry(out, bar, contextPx: number?)
	local s = out.scale or 1
	local ctx = math.ceil((contextPx or 8) / s)
	local T, m = bar.thickness, bar.margin or 0
	local pos = bar.position or "top"
	local x, y, w, h
	if pos == "top" then
		x, y, w, h = out.x, out.y + m, out.width, T + ctx
	elseif pos == "bottom" then
		x, y, w, h = out.x, out.y + out.height - m - T - ctx, out.width, T + ctx
	elseif pos == "left" then
		x, y, w, h = out.x + m, out.y, T + ctx, out.height
	else
		x, y, w, h = out.x + out.width - m - T - ctx, out.y, T + ctx, out.height
	end
	local flipped = pos == "bottom" or pos == "right"
	return {
		geometry = string.format("%d,%d %dx%d", x, y, w, h),
		transpose = pos == "left" or pos == "right",
		flipped = flipped,
		barPx = math.floor(T * s + 0.5),
		vDir = if flipped then -1 else 1,
		scale = s,
	}
end

-- Physical row ranges {y0, y1} of the bar and of the scored band (bar + the
-- 2 rows of its inner edge) in an image with `rows` rows.
function M.rowLayout(flipped: boolean, rows: number, barPx: number)
	local b = math.min(barPx, rows)
	if flipped then
		local c = rows - b
		return { c, rows }, { math.max(c - 2, 0), rows }
	end
	return { 0, b }, { 0, math.min(b + 2, rows) }
end

function M.pruneRegistry(reg, now: number, stale: number)
	local out, changed = {}, false
	for id, info in pairs(reg) do
		if now - (info.t or 0) <= stale then
			out[id] = info
		else
			changed = true
		end
	end
	return out, changed
end

-- Physical px each group is displaced by, for spacer offsets (logical px).
function M.displacements(layout, offsets)
	local out = {}
	for gi, g in ipairs(layout.groups) do
		local d = 0
		for slot, f in pairs(g.factors) do
			d += (offsets[slot] or 0) * f
		end
		out[gi] = math.floor(d + 0.5)
	end
	return out
end

function M.verticalToml(barName: string, margin: number, thickness: number): string
	return table.concat({
		"# Written by the Pixel Shift plugin (mgeldi/pixel-shift) while vertical shift is on.",
		"# It moves the bar content by a pixel or two; the plugin removes this file when",
		"# vertical shift is turned off. Safe to delete.",
		string.format("[bar.%s]", barName),
		string.format("margin_edge = %d", margin),
		string.format("thickness = %d", thickness),
		"",
	}, "\n")
end

function M.side(x: number, w: number): string
	if x < w / 3 then
		return "left"
	elseif x < 2 * w / 3 then
		return "center"
	end
	return "right"
end

return M
```

- [ ] **Step 4: Run to verify pass** — `tools/test.sh util` → `7 passed`.

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/util.luau tests/util_test.luau tests/run.luau
git commit -m "feat(core): pure helpers for paths, ids and geometry"
```

---

### Task 9: `core/layout` — scan captures → motion layout, background, layers

**Files:**
- Create: `pixel-shift/core/layout.luau`
- Test: `tests/layout_test.luau`

**Interfaces:**
- Consumes: `image`, `wear`.
- Produces:
  - `type Group = {x0, x1, own0, own1, factors: {[slot]: number}}` (factor = physical px moved per logical px of spacer width, signed)
  - `type Layout = {w, h, scale, probePx, barRows, scoreRows, vDir, groups: {Group}, slots: {[slot]: {moves: boolean}}, dynamic: {{x0, x1}}}`
  - `build(opts) -> Layout, diff: Image` with `opts = {base, baseB?, probes: {[slot]: Image}, probePx, scale, barRows, scoreRows, vDir}` (all images are linear luma). Groups own every column up to the midpoints between them and extend toward their direction of motion.
  - `background(lin, layout, diff) -> bg: LinearRGB, content: Image`
  - `layers(profile, lin, bg) -> {wbg: Image, dw: Image}`
  - `verify(layout, baseL, bgL, actualL) -> number` (error ratio; > 0.35 means "approximate")

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/layout_test.luau
--!nonstrict
local t = require("./testlib")
local image = require("../pixel-shift/core/image")
local layout = require("../pixel-shift/core/layout")
local wear = require("../pixel-shift/core/wear")

local W, H = 240, 12

-- luma image: background 0.1, bright blocks {x0, x1} on rows 3..8, moved by dx
local function scene(blocks, dx, noise)
	local img = image.new(W, H)
	for y = 0, H - 1 do for x = 0, W - 1 do image.set(img, x, y, 0.1) end end
	for _, b in ipairs(blocks) do
		for y = 3, 8 do
			for x = b[1] + dx, b[2] + dx - 1 do image.set(img, x, y, 0.8) end
		end
	end
	if noise then
		for y = 0, H - 1 do for x = noise[1], noise[2] - 1 do image.set(img, x, y, 0.1 + 0.3 * ((x + y) % 2)) end end
	end
	return img
end

local function opts(probes, scale, probePx)
	return {
		base = scene({ { 40, 44 }, { 60, 92 } }, 0),
		probes = probes,
		probePx = probePx or 8,
		scale = scale or 1,
		barRows = { 0, 10 },
		scoreRows = { 0, 12 },
		vDir = 1,
		maxShift = 16,
	}
end

t.test("layout: one spacer moving a cluster", function()
	local l = layout.build(opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 8) }))
	t.eq(#l.groups, 1)
	local g = l.groups[1]
	t.near(g.factors.a, 1, 1e-9)
	t.ok(g.x0 <= 40 and g.x1 >= 100, "group covers both positions")
	t.eq(g.own0, 0); t.eq(g.own1, W)
	t.eq(g.x1, W, "a right-moving group extends to its right boundary")
	t.eq(l.slots.a.moves, true)
end)

t.test("layout: fractional scale gives physical factors", function()
	local l = layout.build(opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 12) }, 1.5, 8))
	t.near(l.groups[1].factors.a, 1.5, 1e-9)
end)

t.test("layout: spacer that moves nothing is reported", function()
	local l = layout.build(opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 8), b = scene({ { 40, 44 }, { 60, 92 } }, 0) }))
	t.eq(l.slots.b.moves, false)
	t.eq(l.slots.a.moves, true)
end)

t.test("layout: centre spacers merge into one group with opposite factors", function()
	local l = layout.build(opts({
		l = scene({ { 40, 44 }, { 60, 92 } }, 4),
		r = scene({ { 40, 44 }, { 60, 92 } }, -4),
	}))
	t.eq(#l.groups, 1)
	t.near(l.groups[1].factors.l, 0.5, 1e-9)
	t.near(l.groups[1].factors.r, -0.5, 1e-9)
end)

t.test("layout: dynamic columns never create groups", function()
	local o = opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 8, { 180, 190 }) })
	o.baseB = scene({ { 40, 44 }, { 60, 92 } }, 0, { 180, 190 })
	o.base = scene({ { 40, 44 }, { 60, 92 } }, 0, { 181, 191 })
	local l = layout.build(o)
	t.eq(#l.groups, 1)
	t.ok(#l.dynamic >= 1)
end)

t.test("layout: background interpolates under content, layers isolate it", function()
	local l, diff = layout.build(opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 8) }))
	local lin = image.rgbNew(W, H)
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local bgv = 0.05 + 0.1 * x / W -- gentle gradient
			local v = if y >= 3 and y <= 7 and x >= 60 and x < 92 then 0.8 else bgv
			image.set(lin.r, x, y, v); image.set(lin.g, x, y, v); image.set(lin.b, x, y, v)
		end
	end
	local bg, content = layout.background(lin, l, diff)
	t.near(image.get(bg.g, 75, 5), 0.05 + 0.1 * 75 / W, 0.01)
	t.eq(image.get(content, 75, 5), 1)
	t.eq(image.get(content, 150, 5), 0)
	local layers = layout.layers(wear.PROFILES.generic, lin, bg)
	t.ok(image.get(layers.dw, 75, 5) > 0.5)
	t.near(image.get(layers.dw, 150, 5), 0, 1e-6)
end)

t.test("layout: verify accepts the right model and rejects a wrong one", function()
	local base = scene({ { 40, 44 }, { 60, 92 } }, 0)
	local l = layout.build(opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 8) }))
	local bgL = scene({}, 0)
	t.ok(layout.verify(l, base, bgL, scene({ { 40, 44 }, { 60, 92 } }, 8)) < 0.05)
	t.ok(layout.verify(l, base, bgL, scene({ { 40, 44 }, { 60, 92 } }, 2)) > 0.35)
end)

return {}
```

- [ ] **Step 2: Run to verify failure** — `tools/test.sh layout` → FAIL.

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/layout.luau
--!nonstrict
-- Turns scan captures into the bar's motion layout (which columns move with
-- which spacer, and how far), then separates content from the static
-- background so the simulator can move only the content.

local image = require("./image")
local wear = require("./wear")

local M = {}

M.DIFF = 0.02 -- linear luma change that counts as "changed"
M.MIN_COL = 0.05 -- summed change for a column to count
M.MERGE_GAP = 12 -- px: changed runs closer than this merge
M.MEDIAN_R = 12 -- px: median window for the edge-row background line
M.CONTENT = 0.02 -- deviation from that line that marks content
M.VERIFY_LIMIT = 0.35

local function runsOf(cols, minSum, gap)
	local runs, cur = {}, nil
	for x = 0, #cols - 1 do
		if cols[x + 1] > minSum then
			if cur and x - cur[2] <= gap then
				cur[2] = x + 1
			else
				cur = { x, x + 1 }
				table.insert(runs, cur)
			end
		end
	end
	return runs
end

-- Columns whose content changed between two captures taken with identical
-- spacer widths (clock ticks, visualizers).
function M.dynamicColumns(a, b, y0, y1)
	local set = {}
	for x = 0, a.w - 1 do
		for y = y0, y1 - 1 do
			if math.abs(image.get(a, x, y) - image.get(b, x, y)) > M.DIFF then
				set[x] = true
				break
			end
		end
	end
	return set
end

-- Best shift s in [-maxShift, maxShift] with probe(x + s) ~ base(x) over
-- columns [x0, x1). Returns s, its mean absolute difference, and the one at s = 0.
function M.matchShift(base, probe, x0, x1, y0, y1, maxShift, ignore)
	local best, bestS, zero = math.huge, 0, nil
	for s = -maxShift, maxShift do
		local sum, n = 0, 0
		for x = x0, x1 - 1 do
			local px = x + s
			if px >= 0 and px < base.w and not (ignore[x] or ignore[px]) then
				for y = y0, y1 - 1 do
					sum += math.abs(image.get(base, x, y) - image.get(probe, px, y))
				end
				n += 1
			end
		end
		if n > 0 then
			local sad = sum / n
			if s == 0 then
				zero = sad
			end
			if sad < best - 1e-12 then
				best, bestS = sad, s
			end
		end
	end
	return bestS, best, zero or best
end

local function sortedKeys(t)
	local keys = {}
	for k in pairs(t) do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

function M.build(opts)
	local base = opts.base
	local w, h = base.w, base.h
	local y0, y1 = opts.barRows[1], opts.barRows[2]
	local ignore = if opts.baseB then M.dynamicColumns(base, opts.baseB, y0, y1) else {}
	local maxShift = math.ceil(opts.probePx * opts.scale) + 2
	local diff = image.new(w, h)
	local pieces, slots = {}, {}

	for _, slot in ipairs(sortedKeys(opts.probes)) do
		local probe = opts.probes[slot]
		slots[slot] = { moves = false }
		local cols = table.create(w, 0)
		for y = y0, y1 - 1 do
			for x = 0, w - 1 do
				local d = math.abs(image.get(base, x, y) - image.get(probe, x, y))
				if d > M.DIFF then
					image.set(diff, x, y, 1)
					if not ignore[x] then
						cols[x + 1] += d
					end
				end
			end
		end
		for _, r in ipairs(runsOf(cols, M.MIN_COL, M.MERGE_GAP)) do
			local a, b = math.max(r[1] - maxShift, 0), math.min(r[2] + maxShift, w)
			local s, sad, zero = M.matchShift(base, probe, a, b, y0, y1, maxShift, ignore)
			if s ~= 0 and sad < zero * 0.5 then
				slots[slot].moves = true
				table.insert(pieces, { x0 = a, x1 = b, slot = slot, f = s / opts.probePx })
			end
		end
	end

	table.sort(pieces, function(p, q)
		return p.x0 < q.x0
	end)
	local groups = {}
	for _, p in ipairs(pieces) do
		local g = groups[#groups]
		if g and p.x0 <= g.x1 then
			g.x1 = math.max(g.x1, p.x1)
			if g.factors[p.slot] == nil then
				g.factors[p.slot] = p.f
			end
		else
			table.insert(groups, { x0 = p.x0, x1 = p.x1, factors = { [p.slot] = p.f } })
		end
	end

	-- Ownership: every column belongs to the nearest group (split at the
	-- midpoints). A group then grows toward the side it moves to, so content
	-- that appears later there (a longer window title) still moves with it.
	local bounds = {}
	for i, g in ipairs(groups) do
		local left = if i > 1 then (groups[i - 1].x1 + g.x0) // 2 else 0
		local right = if i < #groups then (g.x1 + groups[i + 1].x0) // 2 else w
		bounds[i] = { left, right }
	end
	for i, g in ipairs(groups) do
		g.own0, g.own1 = bounds[i][1], bounds[i][2]
		for _, f in pairs(g.factors) do
			if f > 0 then
				g.x1 = g.own1
			elseif f < 0 then
				g.x0 = g.own0
			end
		end
	end

	local dynamic, cur = {}, nil
	for x = 0, w - 1 do
		if ignore[x] then
			if cur and cur[2] == x then
				cur[2] = x + 1
			else
				cur = { x, x + 1 }
				table.insert(dynamic, cur)
			end
		end
	end

	return {
		w = w,
		h = h,
		scale = opts.scale,
		probePx = opts.probePx,
		barRows = opts.barRows,
		scoreRows = opts.scoreRows,
		vDir = opts.vDir or 1,
		groups = groups,
		slots = slots,
		dynamic = dynamic,
	},
		diff
end

-- Median of a small list (sorts a copy).
local function median(values)
	local c = table.clone(values)
	table.sort(c)
	return c[(#c + 1) // 2]
end

-- Background estimate per column: the bar's top and bottom edge rows are
-- normally padding, so their colour (median over +-MEDIAN_R columns to shrug
-- off the odd widget touching the edge) is interpolated down each column.
local function edgeLine(chan, y0, y1)
	local w = chan.w
	local top, bot = table.create(w, 0), table.create(w, 0)
	local rows = math.min(2, math.max(1, (y1 - y0) // 4))
	for x = 0, w - 1 do
		local a, b = 0, 0
		for k = 0, rows - 1 do
			a += image.get(chan, x, y0 + k)
			b += image.get(chan, x, y1 - 1 - k)
		end
		top[x + 1], bot[x + 1] = a / rows, b / rows
	end
	local mt, mb = table.create(w, 0), table.create(w, 0)
	local win = {}
	for x = 0, w - 1 do
		table.clear(win)
		for k = math.max(x - M.MEDIAN_R, 0), math.min(x + M.MEDIAN_R, w - 1) do
			table.insert(win, top[k + 1])
		end
		mt[x + 1] = median(win)
		table.clear(win)
		for k = math.max(x - M.MEDIAN_R, 0), math.min(x + M.MEDIAN_R, w - 1) do
			table.insert(win, bot[k + 1])
		end
		mb[x + 1] = median(win)
	end
	return function(x, y)
		local f = (y - y0 + 0.5) / (y1 - y0)
		return mt[x + 1] + (mb[x + 1] - mt[x + 1]) * f
	end
end

-- Background under the content. Inside group columns, pixels that deviate
-- from the edge-row line (or changed during the scan) are content and get
-- replaced by interpolation along the row from the nearest background pixels.
-- Outside groups the capture itself is the background.
function M.background(lin, l, diff)
	local w = lin.w
	local chans = { lin.r, lin.g, lin.b }
	local bg = image.rgbMap(lin, image.copy)
	local outs = { bg.r, bg.g, bg.b }
	local raw = image.new(w, lin.h)
	local y0, y1 = l.barRows[1], l.barRows[2]
	local lines = { edgeLine(lin.r, y0, y1), edgeLine(lin.g, y0, y1), edgeLine(lin.b, y0, y1) }

	for _, g in ipairs(l.groups) do
		for y = y0, y1 - 1 do
			for x = math.max(g.x0, 0), math.min(g.x1, w) - 1 do
				local dev = 0
				for c = 1, 3 do
					dev = math.max(dev, math.abs(image.get(chans[c], x, y) - lines[c](x, y)))
				end
				if dev > M.CONTENT or image.get(diff, x, y) > 0 then
					image.set(raw, x, y, 1)
				end
			end
		end
	end

	-- dilate by one column so anti-aliased fringes count as content
	local content = image.copy(raw)
	for y = y0, y1 - 1 do
		for x = 0, w - 1 do
			if image.get(raw, x, y) > 0 then
				if x > 0 then
					image.set(content, x - 1, y, 1)
				end
				if x < w - 1 then
					image.set(content, x + 1, y, 1)
				end
			end
		end
	end

	for y = y0, y1 - 1 do
		local x = 0
		while x < w do
			if image.get(content, x, y) > 0 then
				local a = x
				while x < w and image.get(content, x, y) > 0 do
					x += 1
				end
				local b = x
				for c = 1, 3 do
					local lv = if a > 0 then image.get(chans[c], a - 1, y) else nil
					local rv = if b < w then image.get(chans[c], b, y) else nil
					lv = lv or rv or lines[c](a, y)
					rv = rv or lv
					for xx = a, b - 1 do
						local f = (xx - a + 1) / (b - a + 1)
						image.set(outs[c], xx, y, lv + (rv - lv) * f)
					end
				end
			else
				x += 1
			end
		end
	end
	return bg, content
end

function M.layers(p, lin, bg)
	local wbg = wear.map(p, bg)
	local dw = wear.map(p, lin)
	image.add(dw, wbg, -1)
	return { wbg = wbg, dw = dw }
end

-- Predicted luma with every spacer widened by probePx, compared with the
-- actual capture. Returns |error| / |content| over the bar rows.
function M.verify(l, baseL, bgL, actualL)
	local contentL = image.copy(baseL)
	image.add(contentL, bgL, -1)
	local pred = image.copy(bgL)
	local owned = image.new(baseL.w, 1)
	for _, g in ipairs(l.groups) do
		local d = 0
		for _, f in pairs(g.factors) do
			d += f * l.probePx
		end
		local layer = image.maskColumns(contentL, g.x0, g.x1)
		image.add(pred, image.shiftColumns(layer, 0, layer.w, -math.floor(d + 0.5)))
		for x = math.max(g.x0, 0), math.min(g.x1, baseL.w) - 1 do
			image.set(owned, x, 0, 1)
		end
	end
	local err, mass = 0, 0
	for y = l.barRows[1], l.barRows[2] - 1 do
		for x = 0, baseL.w - 1 do
			local c = image.get(contentL, x, y)
			if image.get(owned, x, 0) == 0 then
				image.set(pred, x, y, image.get(pred, x, y) + c)
			end
			err += math.abs(image.get(pred, x, y) - image.get(actualL, x, y))
			mass += math.abs(c)
		end
	end
	return err / math.max(mass, 1e-6)
end

return M
```

- [ ] **Step 4: Run to verify pass** — `tools/test.sh layout` → `7 passed`.

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/layout.luau tests/layout_test.luau tests/run.luau
git commit -m "feat(core): scan layout, background and content layers"
```

### Task 10: `core/scanstore` — scan image persistence

**Files:**
- Create: `pixel-shift/core/scanstore.luau`
- Test: `tests/scanstore_test.luau`

**Interfaces:**
- Produces: `encode(base: LinearRGB, bg: LinearRGB) -> string`, `decode(s) -> base, bg | nil`.

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/scanstore_test.luau
--!nonstrict
local t = require("./testlib")
local image = require("../pixel-shift/core/image")
local scanstore = require("../pixel-shift/core/scanstore")

t.test("scanstore: round trip", function()
	local a, b = image.rgbNew(3, 2), image.rgbNew(3, 2)
	image.set(a.g, 2, 1, 0.5); image.set(b.b, 0, 0, 0.25)
	local base, bg = scanstore.decode(scanstore.encode(a, b))
	t.eq(base.w, 3); t.eq(base.h, 2)
	t.near(image.get(base.g, 2, 1), 0.5); t.near(image.get(bg.b, 0, 0), 0.25)
end)

t.test("scanstore: garbage and truncation decode to nil", function()
	t.eq(scanstore.decode("garbage"), nil)
	t.eq(scanstore.decode(nil), nil)
	local s = scanstore.encode(image.rgbNew(3, 2), image.rgbNew(3, 2))
	t.eq(scanstore.decode(string.sub(s, 1, #s - 4)), nil)
end)

return {}
```

- [ ] **Step 2: Run to verify failure** — `tools/test.sh scanstore` → FAIL.

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/scanstore.luau
--!nonstrict
-- Binary form of a scan: baseline and background, each as linear RGB f32.

local image = require("./image")

local M = {}
M.MAGIC = "PSS1"
local HEADER = "<c4I4I4"

function M.encode(base, bg): string
	local parts = { string.pack(HEADER, M.MAGIC, base.w, base.h) }
	for _, lin in ipairs({ base, bg }) do
		for _, ch in ipairs({ lin.r, lin.g, lin.b }) do
			table.insert(parts, buffer.tostring(ch.data))
		end
	end
	return table.concat(parts)
end

function M.decode(s: string?)
	if type(s) ~= "string" or #s < string.packsize(HEADER) then
		return nil
	end
	local magic, w, h, pos = string.unpack(HEADER, s)
	if magic ~= M.MAGIC or w <= 0 or h <= 0 then
		return nil
	end
	local plane = w * h * 4
	if #s ~= pos - 1 + 6 * plane then
		return nil
	end
	local src = buffer.fromstring(s)
	local out = {}
	for i = 1, 2 do
		local lin = image.rgbNew(w, h)
		for _, ch in ipairs({ lin.r, lin.g, lin.b }) do
			buffer.copy(ch.data, 0, src, pos - 1, plane)
			pos += plane
		end
		out[i] = lin
	end
	return out[1], out[2]
end

return M
```

- [ ] **Step 4: Run to verify pass** — `tools/test.sh scanstore` → `2 passed`.

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/scanstore.luau tests/scanstore_test.luau tests/run.luau
git commit -m "feat(core): scan persistence format"
```

### Task 11: `core/simulate` — strategy → exposure → risk

**Files:**
- Create: `pixel-shift/core/simulate.luau`
- Test: `tests/simulate_test.luau`

**Interfaces:**
- Consumes: `image`, `risk`, `Layout` from Task 9, `layers = {wbg, dw}`.
- Produces: `type Strategy = {ranges: {[slot]: number}, vertical: number}`; `kernels(group, ranges) -> {{range, dir}}`, `kernelKey(ks) -> string`, `vRows(layout, V)`, `exposure(layers, layout, strategy) -> Image`, `evaluate(layers, layout, strategy, rref) -> {E, R, hist, score}`, `groupHist(layers, layout, gi, ranges, V, rref) -> Hist`, `staticHist(layers, layout, rref) -> Hist`, `CONTEXT = 40`.

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/simulate_test.luau
--!nonstrict
local t = require("./testlib")
local image = require("../pixel-shift/core/image")
local simulate = require("../pixel-shift/core/simulate")
local risk = require("../pixel-shift/core/risk")
local wear = require("../pixel-shift/core/wear")

local W, H = 200, 20
local RREF = risk.reference(wear.PROFILES.generic)

local function fixture()
	local wbg, dw = image.new(W, H), image.new(W, H)
	for y = 0, H - 1 do
		for x = 0, W - 1 do image.set(wbg, x, y, 0.1) end
	end
	for y = 5, 14 do
		image.set(dw, 100, y, 1); image.set(dw, 101, y, 1)
	end
	local layout = {
		w = W, h = H, scale = 1, vDir = 1,
		barRows = { 0, 18 }, scoreRows = { 0, 20 },
		groups = { { x0 = 80, x1 = 130, own0 = 60, own1 = 150, factors = { a = 1 } } },
		slots = { a = { moves = true } },
	}
	return { wbg = wbg, dw = dw }, layout
end

t.test("simulate: kernels and keys", function()
	local ks = simulate.kernels({ factors = { l = 0.5, r = -0.5 } }, { l = 6, r = 4 })
	t.eq(#ks, 2); t.eq(ks[1][1], 3); t.eq(ks[1][2], 1); t.eq(ks[2][1], 2); t.eq(ks[2][2], -1)
	t.eq(simulate.kernelKey(ks), "3,-2")
	t.eq(simulate.vRows({ scale = 1.5 }, 2), 3)
end)

t.test("simulate: exposure spreads the stroke over the range", function()
	local layers, layout = fixture()
	local E0 = simulate.exposure(layers, layout, { ranges = { a = 0 }, vertical = 0 })
	t.near(image.get(E0, 100, 8), 1.1, 1e-6)
	local E4 = simulate.exposure(layers, layout, { ranges = { a = 4 }, vertical = 0 })
	t.near(image.get(E4, 100, 8), 0.3, 1e-6)
	t.near(image.get(E4, 102, 8), 0.5, 1e-6)
	t.near(image.get(E4, 105, 8), 0.3, 1e-6)
	t.near(image.get(E4, 106, 8), 0.1, 1e-6)
	local EV = simulate.exposure(layers, layout, { ranges = { a = 0 }, vertical = 1 })
	t.near(image.get(EV, 100, 15), 0.6, 1e-6)
end)

t.test("simulate: shifting lowers the score", function()
	local layers, layout = fixture()
	local s0 = simulate.evaluate(layers, layout, { ranges = { a = 0 }, vertical = 0 }, RREF).score
	local s6 = simulate.evaluate(layers, layout, { ranges = { a = 6 }, vertical = 0 }, RREF).score
	t.ok(s6 < s0 * 0.8, `expected a clear drop, got {s0} -> {s6}`)
end)

t.test("simulate: group + static histograms match the full evaluation", function()
	local layers, layout = fixture()
	local ranges = { a = 5 }
	local full = simulate.evaluate(layers, layout, { ranges = ranges, vertical = 0 }, RREF)
	local merged = simulate.staticHist(layers, layout, RREF)
	risk.merge(merged, simulate.groupHist(layers, layout, 1, ranges, 0, RREF))
	t.eq(merged.n, full.hist.n)
	t.near(risk.percentile(merged, 0.99), risk.percentile(full.hist, 0.99), 0.02 * RREF)
end)

return {}
```

- [ ] **Step 2: Run to verify failure** — `tools/test.sh simulate` → FAIL.

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/simulate.luau
--!nonstrict
-- Strategy -> exposure -> risk. A group's content layer (its share of dw) is
-- box-blurred once per spacer that moves it; vertical shift blurs all group
-- content along rows. The static background never moves.

local image = require("./image")
local risk = require("./risk")

local M = {}

M.CONTEXT = 40 -- px each side of a group window: coarse blur reach + fine

export type Strategy = { ranges: { [string]: number }, vertical: number }

function M.kernels(group, ranges)
	local ks = {}
	for slot, f in pairs(group.factors) do
		local r = math.floor((ranges[slot] or 0) * math.abs(f) + 0.5)
		if r > 0 then
			table.insert(ks, { r, if f >= 0 then 1 else -1 })
		end
	end
	table.sort(ks, function(a, b)
		if a[1] ~= b[1] then
			return a[1] > b[1]
		end
		return a[2] > b[2]
	end)
	return ks
end

function M.kernelKey(ks): string
	local parts = table.create(#ks)
	for _, k in ipairs(ks) do
		table.insert(parts, tostring(k[1] * k[2]))
	end
	return table.concat(parts, ",")
end

function M.vRows(layout, V: number?): number
	return math.floor((V or 0) * layout.scale + 0.5)
end

local function groupContent(dw, x0, x1, ks)
	local layer = image.maskColumns(dw, x0, x1)
	for _, k in ipairs(ks) do
		layer = image.dirBoxH(layer, k[1], k[2])
	end
	return layer
end

function M.exposure(layers, layout, strategy: Strategy)
	local content = image.new(layers.dw.w, layers.dw.h)
	for _, g in ipairs(layout.groups) do
		image.add(content, groupContent(layers.dw, g.x0, g.x1, M.kernels(g, strategy.ranges)))
	end
	local vr = M.vRows(layout, strategy.vertical)
	if vr > 0 then
		content = image.dirBoxV(content, vr, layout.vDir)
	end
	local E = image.copy(layers.wbg)
	image.add(E, content)
	return E
end

function M.evaluate(layers, layout, strategy: Strategy, rref: number)
	local E = M.exposure(layers, layout, strategy)
	local R = risk.map(E)
	local h = risk.newHist(2 * rref)
	risk.accumulate(h, R, layout.scoreRows[1], layout.scoreRows[2], 0, R.w)
	return { E = E, R = R, hist = h, score = risk.score(h, rref) }
end

-- Risk histogram over one group's ownership columns, computed on a window.
function M.groupHist(layers, layout, gi: number, ranges, V: number, rref: number)
	local g = layout.groups[gi]
	local a, b = g.own0 - M.CONTEXT, g.own1 + M.CONTEXT
	local E = image.crop(layers.wbg, a, b, "clamp")
	local dw = image.crop(layers.dw, a, b)
	local content = groupContent(dw, g.x0 - a, g.x1 - a, M.kernels(g, ranges))
	local vr = M.vRows(layout, V)
	if vr > 0 then
		content = image.dirBoxV(content, vr, layout.vDir)
	end
	image.add(E, content)
	local R = risk.map(E)
	local h = risk.newHist(2 * rref)
	risk.accumulate(h, R, layout.scoreRows[1], layout.scoreRows[2], g.own0 - a, g.own1 - a)
	return h
end

-- Histogram of every column no group owns. Strategy-independent: nothing
-- there moves horizontally, and vertical shift only moves group content.
function M.staticHist(layers, layout, rref: number)
	local R = risk.map(layers.wbg)
	local h = risk.newHist(2 * rref)
	local y0, y1 = layout.scoreRows[1], layout.scoreRows[2]
	local cursor = 0
	for _, g in ipairs(layout.groups) do
		if g.own0 > cursor then
			risk.accumulate(h, R, y0, y1, cursor, g.own0)
		end
		cursor = math.max(cursor, g.own1)
	end
	if cursor < R.w then
		risk.accumulate(h, R, y0, y1, cursor, R.w)
	end
	return h
end

return M
```

`staticHist` uses `wbg` alone: outside groups `dw` is zero by construction (Task 9 only marks content inside groups), so `wbg` is the full exposure there.

- [ ] **Step 4: Run to verify pass** — `tools/test.sh simulate` → `4 passed`.

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/simulate.luau tests/simulate_test.luau tests/run.luau
git commit -m "feat(core): strategy simulation with group windows"
```

### Task 12: `core/optimize` — cached coordinate descent, curve, pick

**Files:**
- Create: `pixel-shift/core/optimize.luau`
- Test: `tests/optimize_test.luau`

**Interfaces:**
- Consumes: `simulate.kernels/kernelKey/vRows/groupHist/staticHist`, `risk.newHist/merge/score`.
- Produces: `new(ctx) -> Opt` with `ctx = {layers, layout, rref, maxShift, maxV, budgets?}`; `Opt:step(budgetMs) -> done`; fields `Opt.done`, `Opt.progress` (0..1), `Opt.best`, `Opt.evals`, `Opt.entries = {{B, V, ranges, score, movement}}`, `Opt.error`; `movement(layout, ranges, V)`, `curve(entries, budgets) -> {h: {number}, v: {number?}}`, `pick(entries, lambda, allowVertical) -> entry`, `lambdaFromSlider(t)`, `sliderFromLambda(l)`, `LAMBDA_DEFAULT = 0.7`.

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/optimize_test.luau
--!nonstrict
local t = require("./testlib")
local image = require("../pixel-shift/core/image")
local optimize = require("../pixel-shift/core/optimize")
local risk = require("../pixel-shift/core/risk")
local wear = require("../pixel-shift/core/wear")

local W, H = 120, 16
local RREF = risk.reference(wear.PROFILES.generic)

local function fixture()
	local wbg, dw = image.new(W, H), image.new(W, H)
	for y = 0, H - 1 do for x = 0, W - 1 do image.set(wbg, x, y, 0.1) end end
	for y = 4, 11 do
		for _, x in ipairs({ 50, 51, 56, 57, 62, 63 }) do image.set(dw, x, y, 1.5) end
	end
	local layout = {
		w = W, h = H, scale = 1, vDir = 1,
		barRows = { 0, 14 }, scoreRows = { 0, 16 },
		groups = { { x0 = 40, x1 = 75, own0 = 20, own1 = 100, factors = { a = 1 } } },
		slots = { a = { moves = true } },
	}
	return { wbg = wbg, dw = dw }, layout
end

local function runAll(opt)
	for _ = 1, 10000 do
		if opt:step(50) then return end
	end
	error("optimizer did not finish")
end

t.test("optimize: lambda slider mapping", function()
	t.near(optimize.lambdaFromSlider(0), 3.0, 1e-9)
	t.near(optimize.lambdaFromSlider(1), 0.1, 1e-9)
	t.near(optimize.sliderFromLambda(0.7), 0.4278, 1e-3)
end)

t.test("optimize: movement in logical px", function()
	local layout = { scale = 1.5, groups = { { factors = { a = 1.5 } } } }
	t.near(optimize.movement(layout, { a = 6 }, 0), 6, 1e-9)
	t.near(optimize.movement(layout, { a = 6 }, 2), 8, 1e-9)
end)

t.test("optimize: curve falls with budget and pick follows lambda", function()
	local layers, layout = fixture()
	local opt = optimize.new({ layers = layers, layout = layout, rref = RREF, maxShift = 8, maxV = 1, budgets = { 0, 2, 4, 6, 8 } })
	runAll(opt)
	t.eq(opt.error, nil)
	t.eq(#opt.entries, 10)
	local c = optimize.curve(opt.entries, { 0, 2, 4, 6, 8 })
	for i = 2, 5 do
		t.ok(c.h[i] <= c.h[i - 1] + 1e-9, "no-vertical curve must not rise")
	end
	t.ok(c.h[5] < c.h[1] * 0.8)
	t.ok(c.v[1] ~= nil)
	t.eq(optimize.pick(opt.entries, 1000, true).B, 0)
	local greedy = optimize.pick(opt.entries, 0, false)
	t.eq(greedy.V, 0)
	t.ok(greedy.score <= c.h[5] + 1e-9)
	t.ok(opt.progress == 1 and opt.done)
end)

return {}
```

- [ ] **Step 2: Run to verify failure** — `tools/test.sh optimize` → FAIL.

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/optimize.luau
--!nonstrict
-- Finds shift ranges that minimise visible burn-in. For every movement
-- budget B (max group displacement, logical px) and vertical range V it runs
-- a cached coordinate descent over the spacer ranges. Work is resumable:
-- step(ms) advances the search a slice at a time.

local simulate = require("./simulate")
local risk = require("./risk")

local M = {}

M.LAMBDA_CALM = 3.0
M.LAMBDA_MAX = 0.1
M.LAMBDA_DEFAULT = 0.7

function M.lambdaFromSlider(t: number): number
	return M.LAMBDA_CALM * (M.LAMBDA_MAX / M.LAMBDA_CALM) ^ math.clamp(t, 0, 1)
end

function M.sliderFromLambda(l: number): number
	return math.log(l / M.LAMBDA_CALM) / math.log(M.LAMBDA_MAX / M.LAMBDA_CALM)
end

-- Largest horizontal displacement any group sees (logical px) plus V.
function M.movement(layout, ranges, V: number?): number
	local m = 0
	for _, g in ipairs(layout.groups) do
		local d = 0
		for slot, f in pairs(g.factors) do
			d += (ranges[slot] or 0) * math.abs(f) / layout.scale
		end
		m = math.max(m, d)
	end
	return m + (V or 0)
end

local Opt = {}
Opt.__index = Opt

function M.new(ctx)
	local self = setmetatable({
		ctx = ctx,
		cache = {},
		evals = 0,
		entries = {},
		best = math.huge,
		progress = 0,
		done = false,
		error = nil,
	}, Opt)
	self.slots = {}
	for slot, info in pairs(ctx.layout.slots) do
		if info.moves then
			table.insert(self.slots, slot)
		end
	end
	table.sort(self.slots)
	self.budgets = ctx.budgets
	if not self.budgets then
		self.budgets = {}
		for B = 0, ctx.maxShift, 2 do
			table.insert(self.budgets, B)
		end
	end
	self.vs = { 0 }
	for v = 1, ctx.maxV or 0 do
		table.insert(self.vs, v)
	end
	self.co = coroutine.create(function()
		self:_run()
	end)
	return self
end

function Opt:_groupHist(gi, ranges, V)
	local layout = self.ctx.layout
	local g = layout.groups[gi]
	local key = `{gi}|{simulate.kernelKey(simulate.kernels(g, ranges))}|{simulate.vRows(layout, V)}`
	local h = self.cache[key]
	if not h then
		h = simulate.groupHist(self.ctx.layers, layout, gi, ranges, V, self.ctx.rref)
		self.cache[key] = h
		self.evals += 1
		coroutine.yield()
	end
	return h
end

function Opt:_score(ranges, V)
	local total = risk.newHist(2 * self.ctx.rref)
	risk.merge(total, self.static)
	for gi = 1, #self.ctx.layout.groups do
		risk.merge(total, self:_groupHist(gi, ranges, V))
	end
	return risk.score(total, self.ctx.rref)
end

-- Largest range for `slot` that keeps every group it moves within budget B.
function Opt:_maxW(slot, B, ranges)
	local layout = self.ctx.layout
	local limit = self.ctx.maxShift
	for _, g in ipairs(layout.groups) do
		local f = g.factors[slot]
		if f and f ~= 0 then
			local other = 0
			for s2, f2 in pairs(g.factors) do
				if s2 ~= slot then
					other += (ranges[s2] or 0) * math.abs(f2) / layout.scale
				end
			end
			limit = math.min(limit, math.floor((B - other) * layout.scale / math.abs(f) + 1e-9))
		end
	end
	return math.max(limit, 0)
end

function Opt:_descend(B, V, start)
	local ranges = table.clone(start)
	local score = self:_score(ranges, V)
	for _ = 1, 2 do
		local improved = false
		for _, slot in ipairs(self.slots) do
			local cur = ranges[slot] or 0
			local bestW, bestS = cur, score
			for W = 0, self:_maxW(slot, B, ranges) do
				if W ~= cur then
					ranges[slot] = W
					local s = self:_score(ranges, V)
					if s < bestS - 1e-9 then
						bestW, bestS = W, s
					end
				end
			end
			ranges[slot] = bestW
			score = bestS
			if bestW ~= cur then
				improved = true
			end
		end
		if not improved then
			break
		end
	end
	return ranges, score
end

function Opt:_run()
	self.static = simulate.staticHist(self.ctx.layers, self.ctx.layout, self.ctx.rref)
	coroutine.yield()
	local total = #self.vs * #self.budgets
	local finished = 0
	for _, V in ipairs(self.vs) do
		local start = {}
		for _, slot in ipairs(self.slots) do
			start[slot] = 0
		end
		for _, B in ipairs(self.budgets) do
			local ranges, score = self:_descend(B, V, start)
			start = ranges
			table.insert(self.entries, {
				B = B,
				V = V,
				ranges = ranges,
				score = score,
				movement = M.movement(self.ctx.layout, ranges, V),
			})
			self.best = math.min(self.best, score)
			finished += 1
			self.progress = finished / total
		end
	end
	self.done = true
end

function Opt:step(budgetMs: number): boolean
	if self.done then
		return true
	end
	local t0 = os.clock()
	repeat
		local ok, err = coroutine.resume(self.co)
		if not ok then
			self.error = tostring(err)
			self.done = true
		end
	until self.done or (os.clock() - t0) * 1000 >= budgetMs
	return self.done
end

-- Per budget: best score without vertical (h) and best with any V >= 1 (v).
function M.curve(entries, budgets)
	local h, v = {}, {}
	for i, B in ipairs(budgets) do
		for _, e in ipairs(entries) do
			if e.B == B then
				if e.V == 0 then
					h[i] = e.score
				elseif v[i] == nil or e.score < v[i] then
					v[i] = e.score
				end
			end
		end
	end
	return { h = h, v = v }
end

function M.pick(entries, lambda: number, allowVertical: boolean)
	local best, bestJ = nil, math.huge
	for _, e in ipairs(entries) do
		if allowVertical or e.V == 0 then
			local J = e.score + lambda * e.movement
			if J < bestJ - 1e-9 then
				best, bestJ = e, J
			end
		end
	end
	return best
end

return M
```

- [ ] **Step 4: Run to verify pass** — `tools/test.sh optimize` → `3 passed`.

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/optimize.luau tests/optimize_test.luau tests/run.luau
git commit -m "feat(core): resumable strategy optimiser"
```

### Task 13: `core/schedule` — triangle waves

**Files:**
- Create: `pixel-shift/core/schedule.luau`
- Test: `tests/schedule_test.luau`

**Interfaces:**
- Produces: `MULTIPLIERS`, `VERTICAL_STEP = 900`, `triangle(t, step, W) -> 0..W` (uniform dwell: every value twice per period `2(W+1)`), `stepSeconds(baseMinutes, index)`, `offsets(strategy, slotOrder, t, baseMinutes) -> {[slot]: px}`, `vertical(V, t) -> px`.

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/schedule_test.luau
--!nonstrict
local t = require("./testlib")
local schedule = require("../pixel-shift/core/schedule")

t.test("schedule: triangle walks 1 px at a time with uniform dwell", function()
	local seq = {}
	for k = 0, 7 do table.insert(seq, schedule.triangle(k * 10, 10, 3)) end
	t.eq(table.concat(seq, ","), "0,1,2,3,3,2,1,0")
	t.eq(schedule.triangle(80, 10, 3), 0)
	t.eq(schedule.triangle(123, 10, 0), 0)
end)

t.test("schedule: step intervals and offsets", function()
	t.near(schedule.stepSeconds(4, 1), 240, 1e-9)
	t.near(schedule.stepSeconds(4, 2), 276.96, 1e-9)
	t.near(schedule.stepSeconds(4, 9), 240, 1e-9)
	local o = schedule.offsets({ ranges = { a = 2, b = 0 } }, { "a", "b" }, 720, 4)
	t.eq(o.a, 2); t.eq(o.b, 0)
	t.eq(schedule.vertical(2, 1800), 2)
end)

return {}
```

- [ ] **Step 2: Run to verify failure** — `tools/test.sh schedule` → FAIL.

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/schedule.luau
--!nonstrict
-- Offsets as a function of wall-clock time. Each slot walks 0..W and back,
-- one pixel per step, dwelling equally on every offset (the endpoints repeat
-- once), which is exactly the uniform distribution the simulator assumes.

local M = {}

M.MULTIPLIERS = { 1.0, 1.154, 1.304, 1.446, 1.593, 1.737, 1.879, 2.021 }
M.VERTICAL_STEP = 900

function M.triangle(t: number, step: number, W: number): number
	if W <= 0 or step <= 0 then
		return 0
	end
	local period = 2 * (W + 1)
	local k = math.floor(t / step) % period
	return if k <= W then k else period - 1 - k
end

function M.stepSeconds(baseMinutes: number, index: number): number
	return baseMinutes * 60 * M.MULTIPLIERS[(index - 1) % #M.MULTIPLIERS + 1]
end

function M.offsets(strategy, slotOrder, t: number, baseMinutes: number)
	local out = {}
	for i, slot in ipairs(slotOrder) do
		out[slot] = M.triangle(t, M.stepSeconds(baseMinutes, i), strategy.ranges[slot] or 0)
	end
	return out
end

function M.vertical(V: number?, t: number): number
	return M.triangle(t, M.VERTICAL_STEP, V or 0)
end

return M
```

- [ ] **Step 4: Run to verify pass** — `tools/test.sh schedule` → `2 passed`.

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/schedule.luau tests/schedule_test.luau tests/run.luau
git commit -m "feat(core): time-based shift schedule"
```

### Task 14: `core/exposure` — exposure accumulator

**Files:**
- Create: `pixel-shift/core/exposure.luau`
- Test: `tests/exposure_test.luau`

**Interfaces:**
- Consumes: `image`, `wear`, `ppm.Rgb8`, `Layout`.
- Produces: `new(w, h)`, `isBlank(rgb8) -> boolean`, `matchesBaseline(capL, baseL, layout, tol?) -> boolean`, `unshift(lin, layout, disp, vRows) -> LinearRGB`, `add(acc, lin, t)`, `meanWear(acc, profileName) -> Image`, `variance(acc) -> Image`, `layers(acc, profileName, scanLayers, layout) -> {wbg, dw}`, `serialize(acc) -> string`, `deserialize(s) -> acc | nil`.

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/exposure_test.luau
--!nonstrict
local t = require("./testlib")
local image = require("../pixel-shift/core/image")
local exposure = require("../pixel-shift/core/exposure")
local ppm = require("../pixel-shift/core/ppm")

local function flat(w, h, v)
	local lin = image.rgbNew(w, h)
	for y = 0, h - 1 do for x = 0, w - 1 do
		image.set(lin.r, x, y, v); image.set(lin.g, x, y, v); image.set(lin.b, x, y, v)
	end end
	return lin
end

local LAYOUT = { w = 8, h = 2, vDir = 1, barRows = { 0, 2 }, scoreRows = { 0, 2 },
	groups = { { x0 = 2, x1 = 6, own0 = 1, own1 = 7, factors = { a = 1 } } } }

t.test("exposure: mean wear and variance", function()
	local acc = exposure.new(2, 1)
	exposure.add(acc, flat(2, 1, 1), 10)
	exposure.add(acc, flat(2, 1, 0), 20)
	t.eq(acc.n, 2); t.eq(acc.first, 10); t.eq(acc.last, 20)
	t.near(image.get(exposure.meanWear(acc, "generic"), 0, 0), 1.15, 1e-5)
	t.near(image.get(exposure.variance(acc), 0, 0), 0.25, 1e-5)
end)

t.test("exposure: blank frames and baseline matching", function()
	t.eq(exposure.isBlank(ppm.new(10, 10)), true)
	local img = ppm.new(10, 10)
	for x = 0, 9 do ppm.set(img, x, 0, 200, 200, 200) end
	t.eq(exposure.isBlank(img), false)
	local base = image.luma(flat(8, 2, 0.2))
	t.eq(exposure.matchesBaseline(base, base, LAYOUT), true)
	t.eq(exposure.matchesBaseline(image.luma(flat(8, 2, 0.9)), base, LAYOUT), false)
end)

t.test("exposure: unshift moves group content back", function()
	local lin = flat(8, 2, 0)
	image.set(lin.g, 5, 0, 1) -- content captured 2 px right of home (home x = 3)
	local back = exposure.unshift(lin, LAYOUT, { 2 }, 0)
	t.near(image.get(back.g, 3, 0), 1); t.near(image.get(back.g, 5, 0), 0)
end)

t.test("exposure: layers take scan background inside groups", function()
	local acc = exposure.new(8, 2)
	exposure.add(acc, flat(8, 2, 1), 1)
	local scan = { wbg = image.new(8, 2), dw = image.new(8, 2) }
	local layers = exposure.layers(acc, "generic", scan, LAYOUT)
	t.near(image.get(layers.wbg, 3, 0), 0); t.near(image.get(layers.dw, 3, 0), 2.3, 1e-5)
	t.near(image.get(layers.wbg, 0, 0), 2.3, 1e-5); t.near(image.get(layers.dw, 0, 0), 0)
end)

t.test("exposure: serialisation round trip and rejection", function()
	local acc = exposure.new(3, 2)
	exposure.add(acc, flat(3, 2, 0.5), 7)
	local back = exposure.deserialize(exposure.serialize(acc))
	t.eq(back.n, 1); t.eq(back.first, 7)
	t.near(image.get(back.wear.generic, 1, 1), image.get(acc.wear.generic, 1, 1))
	t.eq(exposure.deserialize("junk"), nil)
	local s = exposure.serialize(acc)
	t.eq(exposure.deserialize(string.sub(s, 1, #s - 1)), nil)
end)

return {}
```

- [ ] **Step 2: Run to verify failure** — `tools/test.sh exposure` → FAIL.

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/exposure.luau
--!nonstrict
-- Running exposure of the bar across the day: summed wear per profile (so
-- the panel profile can change later) plus luma sums for a variance map that
-- reveals dynamic content. Samples are stored un-shifted (home positions).

local image = require("./image")
local wear = require("./wear")

local M = {}
M.MAGIC = "PSX1"
local HEADER = "<c4I4I4I4dd"
local PLANES = { "generic", "woled", "qdoled", "lum", "lum2" }

function M.new(w: number, h: number)
	local acc = { w = w, h = h, n = 0, first = 0, last = 0, wear = {}, lum = image.new(w, h), lum2 = image.new(w, h) }
	for _, name in ipairs(wear.ORDER) do
		acc.wear[name] = image.new(w, h)
	end
	return acc
end

-- A capture where fewer than 1 % of pixels rise above 12/255: output off.
function M.isBlank(img): boolean
	local d = img.data
	local n = img.w * img.h
	local bright = 0
	for i = 0, n - 1 do
		local o = i * 3
		if buffer.readu8(d, o) > 12 or buffer.readu8(d, o + 1) > 12 or buffer.readu8(d, o + 2) > 12 then
			bright += 1
		end
	end
	return bright < n * 0.01
end

-- Does the capture still show the scanned bar? Mean luma difference over
-- the bar rows. Changing titles move it a little; a lock screen, a
-- fullscreen app or a new wallpaper move it a lot.
function M.matchesBaseline(capL, baseL, layout, tol: number?): boolean
	local sum, n = 0, 0
	for y = layout.barRows[1], layout.barRows[2] - 1 do
		for x = 0, baseL.w - 1 do
			sum += math.abs(image.get(capL, x, y) - image.get(baseL, x, y))
			n += 1
		end
	end
	if n == 0 then
		return true
	end
	return sum / n < (tol or 0.06)
end

-- Undo the displacement active when the frame was captured: group gi's
-- content sits disp[gi] px right of home, and vRows rows along vDir.
function M.unshift(lin, layout, disp, vRows: number)
	local function fix(img)
		local out = img
		for gi, g in ipairs(layout.groups) do
			local d = disp[gi] or 0
			if d ~= 0 then
				out = image.shiftColumns(out, g.x0, g.x1, d)
			end
		end
		if vRows ~= 0 then
			out = image.shiftRows(out, vRows * layout.vDir)
		end
		return out
	end
	return image.rgbMap(lin, fix)
end

function M.add(acc, lin, t: number)
	for name, sum in pairs(acc.wear) do
		image.add(sum, wear.map(wear.profile(name), lin))
	end
	local L = image.luma(lin)
	image.add(acc.lum, L)
	image.add(acc.lum2, image.square(L))
	acc.n += 1
	if acc.n == 1 then
		acc.first = t
	end
	acc.last = t
end

local function scaled(img, s)
	local out = image.new(img.w, img.h)
	image.add(out, img, s)
	return out
end

function M.meanWear(acc, name: string)
	return scaled(acc.wear[name] or acc.wear.generic, 1 / math.max(acc.n, 1))
end

function M.variance(acc)
	local inv = 1 / math.max(acc.n, 1)
	local mean = scaled(acc.lum, inv)
	local out = scaled(acc.lum2, inv)
	image.add(out, image.square(mean), -1)
	return out
end

-- Simulation layers from the day's exposure: inside group columns the scan's
-- background plus the mean extra wear; elsewhere the mean wear itself.
function M.layers(acc, name: string, scan, layout)
	local mean = M.meanWear(acc, name)
	local wbg = image.copy(mean)
	local dw = image.new(mean.w, mean.h)
	for _, g in ipairs(layout.groups) do
		for y = 0, mean.h - 1 do
			for x = math.max(g.x0, 0), math.min(g.x1, mean.w) - 1 do
				local b = image.get(scan.wbg, x, y)
				image.set(wbg, x, y, b)
				image.set(dw, x, y, image.get(mean, x, y) - b)
			end
		end
	end
	return { wbg = wbg, dw = dw }
end

local function planes(acc)
	return { acc.wear.generic, acc.wear.woled, acc.wear.qdoled, acc.lum, acc.lum2 }
end

function M.serialize(acc): string
	local parts = { string.pack(HEADER, M.MAGIC, acc.w, acc.h, acc.n, acc.first, acc.last) }
	for _, img in ipairs(planes(acc)) do
		table.insert(parts, buffer.tostring(img.data))
	end
	return table.concat(parts)
end

function M.deserialize(s: string?)
	if type(s) ~= "string" or #s < string.packsize(HEADER) then
		return nil
	end
	local magic, w, h, n, first, last, pos = string.unpack(HEADER, s)
	if magic ~= M.MAGIC or w <= 0 or h <= 0 then
		return nil
	end
	local plane = w * h * 4
	if #s ~= pos - 1 + #PLANES * plane then
		return nil
	end
	local acc = M.new(w, h)
	acc.n, acc.first, acc.last = n, first, last
	local src = buffer.fromstring(s)
	for _, img in ipairs(planes(acc)) do
		buffer.copy(img.data, 0, src, pos - 1, plane)
		pos += plane
	end
	return acc
end

return M
```

- [ ] **Step 4: Run to verify pass** — `tools/test.sh exposure` → `5 passed`.

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/exposure.luau tests/exposure_test.luau tests/run.luau
git commit -m "feat(core): exposure accumulator"
```

---

### Task 15: `core/hotspots` — regions and causes

**Files:**
- Create: `pixel-shift/core/hotspots.luau`
- Test: `tests/hotspots_test.luau`

**Interfaces:**
- Consumes: `image`, `util.side`, `simulate.kernels`.
- Produces: `find(opts) -> {{x0, x1, y0, y1, peak, cause, side}}` sorted by `peak` (score units, 100 = reference line), at most `MAX = 4`; `opts = {R, dw, wWhite, variance?, layout, rref, strategy}`; causes `"outside" | "dynamic" | "wide" | "horizontal" | "bright" | "static"`.

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/hotspots_test.luau
--!nonstrict
local t = require("./testlib")
local image = require("../pixel-shift/core/image")
local hotspots = require("../pixel-shift/core/hotspots")

local W, H = 300, 16
local RREF = 1.0
local LAYOUT = {
	w = W, h = H, barRows = { 0, 12 }, scoreRows = { 0, 14 }, dynamic = { { 250, 260 } },
	groups = { { x0 = 0, x1 = W, own0 = 0, own1 = W, factors = { a = 1 } } },
}

local function paint(img, x0, x1, y0, y1, v)
	for y = y0, y1 - 1 do for x = x0, x1 - 1 do image.set(img, x, y, v) end end
end

local function find(R, dw, variance)
	return hotspots.find({ R = R, dw = dw, wWhite = 2.3, variance = variance, layout = LAYOUT, rref = RREF,
		strategy = { ranges = { a = 4 }, vertical = 0 } })
end

t.test("hotspots: causes", function()
	local R, dw = image.new(W, H), image.new(W, H)
	paint(R, 20, 60, 3, 9, 0.9); paint(dw, 20, 60, 3, 9, 1.0)           -- 40 px solid fill: wide
	paint(R, 100, 140, 5, 6, 0.8)                                        -- thin row: horizontal
	paint(R, 180, 184, 4, 8, 0.7); paint(dw, 180, 184, 4, 8, 2.0)       -- small bright block
	paint(R, 252, 256, 4, 8, 0.6)                                        -- scan-time dynamic columns
	paint(R, 200, 230, 14, 16, 0.95)                                     -- context rows only: outside
	local list = find(R, dw)
	local byX = {}
	for _, h in ipairs(list) do byX[h.x0] = h end
	t.eq(#list, 4, "capped at MAX")
	t.eq(list[1].cause, "outside")
	t.eq(byX[20].cause, "wide")
	t.eq(byX[100].cause, "horizontal")
	t.eq(byX[180].cause, "bright")
	t.near(list[1].peak, 95, 1e-4)
	t.eq(byX[20].side, "left")
end)

t.test("hotspots: sample variance marks dynamic content", function()
	local R, dw, var = image.new(W, H), image.new(W, H), image.new(W, H)
	paint(R, 120, 130, 4, 8, 0.8); paint(var, 120, 130, 4, 8, 0.05)
	local list = find(R, dw, var)
	t.eq(list[1].cause, "dynamic")
	t.eq(list[1].side, "center")
end)

return {}
```

- [ ] **Step 2: Run to verify failure** — `tools/test.sh hotspots` → FAIL.

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/hotspots.luau
--!nonstrict
-- Groups risky pixels into regions and names the likely cause, so the lab
-- can say what shifting cannot fix and what to change instead.

local image = require("./image")
local util = require("./util")
local simulate = require("./simulate")

local M = {}

M.THRESHOLD = 0.35 -- fraction of the reference risk
M.GAP = 6 -- px between hot columns that still merge
M.MAX = 4
M.VAR_DYNAMIC = 0.002 -- luma variance across samples

local function regionsIn(R, thr, y0, y1, outside, out)
	local cur
	for x = 0, R.w - 1 do
		local hot = false
		for y = y0, y1 - 1 do
			if image.get(R, x, y) > thr then
				hot = true
				break
			end
		end
		if hot then
			if cur and x - cur.x1 <= M.GAP then
				cur.x1 = x + 1
			else
				cur = { x0 = x, x1 = x + 1, y0 = y0, y1 = y1, outside = outside }
				table.insert(out, cur)
			end
		end
	end
end

local function refine(reg, R, thr)
	local peak, ry0, ry1 = 0, math.huge, -1
	for y = reg.y0, reg.y1 - 1 do
		for x = reg.x0, reg.x1 - 1 do
			local v = image.get(R, x, y)
			if v > peak then
				peak = v
			end
			if v > thr then
				ry0 = math.min(ry0, y)
				ry1 = math.max(ry1, y)
			end
		end
	end
	reg.peakRaw, reg.y0, reg.y1 = peak, ry0, ry1 + 1
end

local function groupAt(layout, x)
	for _, g in ipairs(layout.groups) do
		if x >= g.own0 and x < g.own1 then
			return g
		end
	end
	return nil
end

-- Longest run along a row (region rows, region columns +-40 px) of dw above thr.
local function longestRun(dw, reg, thr)
	local best = 0
	local a, b = math.max(reg.x0 - 40, 0), math.min(reg.x1 + 40, dw.w)
	for y = reg.y0, reg.y1 - 1 do
		local run = 0
		for x = a, b - 1 do
			if image.get(dw, x, y) > thr then
				run += 1
				best = math.max(best, run)
			else
				run = 0
			end
		end
	end
	return best
end

local function gradients(R, reg)
	local gx, gy = 0, 0
	for y = math.max(reg.y0 - 1, 0), math.min(reg.y1, R.h - 1) - 1 do
		for x = math.max(reg.x0 - 1, 0), math.min(reg.x1, R.w - 1) - 1 do
			local v = image.get(R, x, y)
			gx += math.abs(image.get(R, x + 1, y) - v)
			gy += math.abs(image.get(R, x, y + 1) - v)
		end
	end
	return gx, gy
end

local function meanOver(img, reg, pred)
	local sum, n = 0, 0
	for y = reg.y0, reg.y1 - 1 do
		for x = reg.x0, reg.x1 - 1 do
			local v = image.get(img, x, y)
			if pred == nil or pred(v) then
				sum += v
				n += 1
			end
		end
	end
	return if n > 0 then sum / n else 0
end

local function cause(reg, opts)
	if reg.outside then
		return "outside"
	end
	if opts.variance and meanOver(opts.variance, reg) > M.VAR_DYNAMIC then
		return "dynamic"
	end
	for _, d in ipairs(opts.layout.dynamic or {}) do
		if reg.x0 < d[2] and reg.x1 > d[1] then
			return "dynamic"
		end
	end
	local range = 0
	local g = groupAt(opts.layout, (reg.x0 + reg.x1) // 2)
	if g then
		for _, k in ipairs(simulate.kernels(g, opts.strategy.ranges)) do
			range += k[1]
		end
	end
	if longestRun(opts.dw, reg, 0.1 * opts.wWhite) > 2 * range + 6 then
		return "wide"
	end
	local gx, gy = gradients(opts.R, reg)
	if gy > 2 * gx then
		return "horizontal"
	end
	local lit = meanOver(opts.dw, reg, function(v)
		return v > 0.1 * opts.wWhite
	end)
	if lit > 0.6 * opts.wWhite then
		return "bright"
	end
	return "static"
end

function M.find(opts)
	local R, layout = opts.R, opts.layout
	local thr = M.THRESHOLD * opts.rref
	local sy0, sy1 = layout.scoreRows[1], layout.scoreRows[2]
	local regions = {}
	regionsIn(R, thr, sy0, sy1, false, regions)
	if sy0 > 0 then
		regionsIn(R, thr, 0, sy0, true, regions)
	end
	if sy1 < R.h then
		regionsIn(R, thr, sy1, R.h, true, regions)
	end
	for _, reg in ipairs(regions) do
		refine(reg, R, thr)
		reg.peak = 100 * reg.peakRaw / opts.rref
		reg.cause = cause(reg, opts)
		reg.side = util.side((reg.x0 + reg.x1) / 2, R.w)
	end
	table.sort(regions, function(a, b)
		return a.peak > b.peak
	end)
	local out = {}
	for i = 1, math.min(M.MAX, #regions) do
		local r = regions[i]
		out[i] = { x0 = r.x0, x1 = r.x1, y0 = r.y0, y1 = r.y1, peak = r.peak, cause = r.cause, side = r.side }
	end
	return out
end

return M
```

- [ ] **Step 4: Run to verify pass** — `tools/test.sh hotspots` → `2 passed`.

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/hotspots.luau tests/hotspots_test.luau tests/run.luau
git commit -m "feat(core): hotspot regions and causes"
```

### Task 16: `core/render` — lab images

**Files:**
- Create: `pixel-shift/core/render.luau`
- Test: `tests/render_test.luau`

**Interfaces:**
- Consumes: `image`, `ppm`, `color`.
- Produces: `ghostGray(E, eRef) -> Image`, `glow(base, R, rTop, ramp) -> Rgb8`, `ghostView(E, R, eRef, rTop, ramp) -> Rgb8`, `riskView(lum, R, rTop, ramp) -> Rgb8`, `fromLinear(lin) -> Rgb8`, `scaleDown(img, newW) -> Rgb8`, `halves(img, targetW) -> left, right`, `zoom(img, x0, x1, y0, y1, z) -> Rgb8`, `frame(img, x0, x1, rgb)` (outline drawn in place), `legend(ramp, w, h) -> Rgb8`.

- [ ] **Step 1: Write the failing tests**

```lua
-- file: tests/render_test.luau
--!nonstrict
local t = require("./testlib")
local image = require("../pixel-shift/core/image")
local ppm = require("../pixel-shift/core/ppm")
local color = require("../pixel-shift/core/color")
local render = require("../pixel-shift/core/render")

t.test("render: ghost grey range", function()
	local E = image.new(2, 1)
	image.set(E, 1, 0, 5)
	local g = render.ghostGray(E, 5)
	t.near(image.get(g, 0, 0), 0.6 * 0.72, 1e-6)
	t.near(image.get(g, 1, 0), 0.2 * 0.72, 1e-6)
end)

t.test("render: glow is the base where risk is zero and the ramp top at the peak", function()
	local base, R = image.new(9, 9), image.new(9, 9)
	for y = 0, 8 do for x = 0, 8 do image.set(base, x, y, 0.5); image.set(R, x, y, 0) end end
	for y = 2, 6 do for x = 2, 6 do image.set(R, x, y, 2) end end
	local ramp = color.glowRamp("#c1c5de")
	local out = render.glow(base, R, 1, ramp)
	local r0 = ppm.get(out, 0, 0)
	t.eq(r0, 128)
	local r, g, b = ppm.get(out, 4, 4)
	t.eq(r, ramp[256][1]); t.eq(g, ramp[256][2]); t.eq(b, ramp[256][3])
end)

t.test("render: scaleDown, halves, zoom, frame, legend", function()
	local img = ppm.new(4, 2)
	ppm.set(img, 0, 0, 100, 0, 0); ppm.set(img, 1, 0, 200, 0, 0)
	local s = render.scaleDown(img, 2)
	t.eq(s.w, 2); t.eq(s.h, 1)
	t.eq((ppm.get(s, 0, 0)), 75)
	local left, right = render.halves(img, 2)
	t.eq(left.w, 2); t.eq(right.w, 2)
	local z = render.zoom(img, 0, 2, 0, 1, 3)
	t.eq(z.w, 6); t.eq(z.h, 3)
	t.eq((ppm.get(z, 4, 2)), 200)
	local f = ppm.new(6, 4)
	render.frame(f, 1, 4, { 9, 8, 7 })
	t.eq((ppm.get(f, 1, 0)), 9); t.eq((ppm.get(f, 2, 1)), 0); t.eq((ppm.get(f, 3, 3)), 9)
	local lg = render.legend(color.glowRamp("#c1c5de"), 64, 4)
	t.eq(lg.w, 64); t.eq(lg.h, 4)
end)

return {}
```

- [ ] **Step 2: Run to verify failure** — `tools/test.sh render` → FAIL.

- [ ] **Step 3: Implement**

```lua
-- file: pixel-shift/core/render.luau
--!nonstrict
-- Lab images: the ghost preview with theme-coloured glow proportional to
-- risk (one absolute scale for every view), the risk view, and the helpers
-- that size them for the panel.

local image = require("./image")
local ppm = require("./ppm")
local color = require("./color")

local rf = buffer.readf32
local wu8, ru8 = buffer.writeu8, buffer.readu8

local M = {}

local function smoothstep(e0, e1, x)
	local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

local function byte(v)
	v = math.floor(v + 0.5)
	return if v < 0 then 0 elseif v > 255 then 255 else v
end

-- What the bar leaves on a flat mid-grey screen: grey 0..1 (sRGB).
function M.ghostGray(E, eRef: number)
	local out = image.new(E.w, E.h)
	local inv = 1 / math.max(eRef, 1e-9)
	for o = 0, (E.w * E.h - 1) * 4, 4 do
		local e = math.clamp(rf(E.data, o) * inv, 0, 1)
		buffer.writef32(out.data, o, (0.60 - 0.40 * e ^ 0.8) * 0.72)
	end
	return out
end

-- Composite the risk glow over a grey base (spec 5.2).
function M.glow(base, R, rTop: number, ramp)
	local w, h = R.w, R.h
	local t = image.new(w, h)
	local inv = 1 / math.max(rTop, 1e-9)
	for o = 0, (w * h - 1) * 4, 4 do
		buffer.writef32(t.data, o, math.clamp(rf(R.data, o) * inv, 0, 1))
	end
	local bloom = image.gauss3(t, 1)
	local out = ppm.new(w, h)
	for i = 0, w * h - 1 do
		local o = i * 4
		local tt = math.min(rf(t.data, o) + 0.35 * rf(bloom.data, o), 1)
		local a = smoothstep(0.16, 0.55, tt)
		local c = ramp[math.floor(tt * 255) + 1]
		local g = rf(base.data, o) * 255
		local d = i * 3
		wu8(out.data, d, byte(g * (1 - a) + c[1] * a))
		wu8(out.data, d + 1, byte(g * (1 - a) + c[2] * a))
		wu8(out.data, d + 2, byte(g * (1 - a) + c[3] * a))
	end
	return out
end

function M.ghostView(E, R, eRef: number, rTop: number, ramp)
	return M.glow(M.ghostGray(E, eRef), R, rTop, ramp)
end

-- Dimmed bar (20 % of its sRGB luma) with the risk ramp on top.
function M.riskView(lum, R, rTop: number, ramp)
	local w, h = R.w, R.h
	local out = ppm.new(w, h)
	local inv = 1 / math.max(rTop, 1e-9)
	for i = 0, w * h - 1 do
		local o = i * 4
		local tr = math.clamp(rf(R.data, o) * inv, 0, 1) ^ 0.7
		local a = math.clamp(1.4 * tr, 0, 1)
		local g = color.fromLinear(rf(lum.data, o)) * 0.2 * 255
		local c = ramp[math.floor(tr * 255) + 1]
		local d = i * 3
		wu8(out.data, d, byte(g * (1 - a) + c[1] * a))
		wu8(out.data, d + 1, byte(g * (1 - a) + c[2] * a))
		wu8(out.data, d + 2, byte(g * (1 - a) + c[3] * a))
	end
	return out
end

function M.fromLinear(lin)
	local out = ppm.new(lin.w, lin.h)
	for i = 0, lin.w * lin.h - 1 do
		local o, d = i * 4, i * 3
		wu8(out.data, d, color.to8(color.fromLinear(rf(lin.r.data, o))))
		wu8(out.data, d + 1, color.to8(color.fromLinear(rf(lin.g.data, o))))
		wu8(out.data, d + 2, color.to8(color.fromLinear(rf(lin.b.data, o))))
	end
	return out
end

-- Area-average downscale to width newW, keeping the aspect ratio.
function M.scaleDown(img, newW: number)
	local f = img.w / newW
	local newH = math.max(1, math.floor(img.h / f + 0.5))
	local out = ppm.new(newW, newH)
	for oy = 0, newH - 1 do
		local sy0 = math.floor(oy * f)
		local sy1 = math.max(sy0 + 1, math.min(math.floor((oy + 1) * f), img.h))
		for ox = 0, newW - 1 do
			local sx0 = math.floor(ox * f)
			local sx1 = math.max(sx0 + 1, math.min(math.floor((ox + 1) * f), img.w))
			local r, g, b, n = 0, 0, 0, 0
			for y = sy0, sy1 - 1 do
				for x = sx0, sx1 - 1 do
					local s = (y * img.w + x) * 3
					r += ru8(img.data, s)
					g += ru8(img.data, s + 1)
					b += ru8(img.data, s + 2)
					n += 1
				end
			end
			local d = (oy * newW + ox) * 3
			wu8(out.data, d, byte(r / n))
			wu8(out.data, d + 1, byte(g / n))
			wu8(out.data, d + 2, byte(b / n))
		end
	end
	return out
end

local function cropRgb(img, x0, x1, y0, y1)
	local w, h = x1 - x0, y1 - y0
	local out = ppm.new(w, h)
	for y = 0, h - 1 do
		buffer.copy(out.data, y * w * 3, img.data, ((y + y0) * img.w + x0) * 3, w * 3)
	end
	return out
end

-- The whole bar as two exact halves, each scaled to targetW.
function M.halves(img, targetW: number)
	local mid = img.w // 2
	return M.scaleDown(cropRgb(img, 0, mid, 0, img.h), targetW),
		M.scaleDown(cropRgb(img, mid, img.w, 0, img.h), targetW)
end

-- Nearest-neighbour zoom of a region (pixels stay crisp in the inspector).
function M.zoom(img, x0: number, x1: number, y0: number, y1: number, z: number)
	x0, x1 = math.max(x0, 0), math.min(x1, img.w)
	y0, y1 = math.max(y0, 0), math.min(y1, img.h)
	local w, h = (x1 - x0) * z, (y1 - y0) * z
	local out = ppm.new(w, h)
	for y = 0, h - 1 do
		local sy = y0 + y // z
		for x = 0, w - 1 do
			buffer.copy(out.data, (y * w + x) * 3, img.data, (sy * img.w + x0 + x // z) * 3, 3)
		end
	end
	return out
end

-- 1 px outline around columns [x0, x1) over the full height, drawn in place.
function M.frame(img, x0: number, x1: number, rgb)
	x0, x1 = math.max(x0, 0), math.min(x1, img.w)
	for x = x0, x1 - 1 do
		ppm.set(img, x, 0, rgb[1], rgb[2], rgb[3])
		ppm.set(img, x, img.h - 1, rgb[1], rgb[2], rgb[3])
	end
	for y = 0, img.h - 1 do
		ppm.set(img, x0, y, rgb[1], rgb[2], rgb[3])
		ppm.set(img, x1 - 1, y, rgb[1], rgb[2], rgb[3])
	end
end

-- Horizontal legend strip: neutral grey fading into the glow ramp.
function M.legend(ramp, w: number, h: number)
	local out = ppm.new(w, h)
	for x = 0, w - 1 do
		local t = x / math.max(w - 1, 1)
		local a = smoothstep(0.16, 0.55, t)
		local c = ramp[math.floor(t * 255) + 1]
		local g = 0.43 * 255
		for y = 0, h - 1 do
			ppm.set(out, x, y, byte(g * (1 - a) + c[1] * a), byte(g * (1 - a) + c[2] * a), byte(g * (1 - a) + c[3] * a))
		end
	end
	return out
end

return M
```

- [ ] **Step 4: Run to verify pass** — `tools/test.sh render` → `3 passed`.

- [ ] **Step 5: Commit**

```bash
git add pixel-shift/core/render.luau tests/render_test.luau tests/run.luau
git commit -m "feat(core): ghost, glow and risk renderers"
```

---

### Task 17: Spacer widget and engine helper modules

**Files:**
- Replace: `pixel-shift/spacer.luau`
- Create: `pixel-shift/engine/tasks.luau`, `pixel-shift/engine/capture.luau`, `pixel-shift/engine/store.luau`, `pixel-shift/engine/vertical.luau`

**Interfaces:**
- Shared state keys (all entries):
  - `spacer:hello` ← spacer `{id, output, vertical}`; `spacer:bye` ← spacer `{id}`
  - `spacer:count:<output>` counter used for stable ordinal ids `<output>#<n>`
  - `spacers:known` ← engine `{[id]: output}`; `engine:epoch` ← engine (spacers re-announce)
  - `offsets` ← engine `{seq, [id]: widthPx}`; `ack:<id>` ← spacer `seq`
  - `lab:cmd` ← lab/toggle `{seq, cmd, arg}`; `lab:model` ← engine; `paused` ← engine
- `tasks.spawn(name, fn)`, `tasks.await(start)`, `tasks.sleep(ms)`, `tasks.waitFor(pred, ms)`, `tasks.tick()`, `tasks.active()`, `tasks.running(name)`
- `capture.available()`, `capture.grab(geometry, transpose) -> Rgb8? , err?` (inside a task)
- `store.readJson(name)`, `store.writeJson(name, v)`, `store.read(name)`, `store.write(name, s)`, `store.remove(name)`, `store.writeImage(slot, bytes) -> path?`, `store.cleanRenders()`
- `vertical.path()`, `vertical.active()`, `vertical.apply(base, v)`, `vertical.clear()`, `vertical.effective(base, v)`; `base = {bar, margin, thickness}` (raw config values)

- [ ] **Step 1: Write the modules**

```lua
-- file: pixel-shift/spacer.luau
--!nonstrict
-- Invisible bar widget. Its width is the current pixel-shift offset for this
-- slot; the engine service decides every width, this entry only draws it.

local id = nil
local width = 0
local known = false
local lastHello = -math.huge

-- Widgets load one after another in bar order, so a per-output counter gives
-- each spacer the same id on every start.
local function ensureId(): boolean
	if id then
		return true
	end
	local output = barWidget.outputName()
	if not output then
		return false
	end
	local key = "spacer:count:" .. output
	local n = (noctalia.state.get(key) or 0) + 1
	noctalia.state.set(key, n)
	id = `{output}#{n}`
	return true
end

local function render()
	local w = math.max(width, 0)
	if barWidget.isVertical() then
		barWidget.render(ui.box({ width = 1, height = w, fill = "#00000000" }))
	else
		barWidget.render(ui.box({ width = w, height = 1, fill = "#00000000" }))
	end
end

local function hello()
	if not ensureId() then
		return
	end
	lastHello = os.time()
	noctalia.state.set("spacer:hello", { id = id, output = barWidget.outputName(), vertical = barWidget.isVertical() })
end

noctalia.state.watch("spacers:known", function(v)
	known = type(v) == "table" and id ~= nil and v[id] ~= nil
end)

noctalia.state.watch("engine:epoch", function()
	known = false
	hello()
end)

noctalia.state.watch("offsets", function(v)
	if type(v) ~= "table" or id == nil then
		return
	end
	local w = tonumber(v[id]) or 0
	if w ~= width then
		width = w
		render()
	end
	noctalia.state.set("ack:" .. id, v.seq or 0)
end)

function update()
	noctalia.setUpdateInterval(1000)
	local now = os.time()
	if (not known and now - lastHello >= 1) or now - lastHello >= 30 then
		hello()
	end
end

function onExit()
	if id then
		noctalia.state.set("spacer:bye", { id = id })
	end
end

render()
hello()
```

```lua
-- file: pixel-shift/engine/tasks.luau
--!nonstrict
-- Tiny coroutine runner so async steps (captures, waits) read top to bottom.
-- Tasks are resumed from the engine's update() tick, never from callbacks.

local M = {}
local running = {}

function M.spawn(name: string, fn: () -> ())
	table.insert(running, { name = name, co = coroutine.create(fn) })
end

-- Inside a task: start a callback-style operation and wait for its result.
function M.await(start: ((...any) -> ()) -> ())
	local result = nil
	start(function(...)
		result = table.pack(...)
	end)
	while result == nil do
		coroutine.yield()
	end
	return table.unpack(result, 1, result.n)
end

function M.sleep(ms: number)
	local untilMs = noctalia.nowMs() + ms
	repeat
		coroutine.yield()
	until noctalia.nowMs() >= untilMs
end

function M.waitFor(pred: () -> boolean, timeoutMs: number): boolean
	local untilMs = noctalia.nowMs() + timeoutMs
	while not pred() do
		if noctalia.nowMs() >= untilMs then
			return false
		end
		coroutine.yield()
	end
	return true
end

function M.tick()
	for i = #running, 1, -1 do
		local t = running[i]
		local ok, err = coroutine.resume(t.co)
		if not ok then
			noctalia.log(`pixel-shift: task {t.name} failed: {tostring(err)}`)
			table.remove(running, i)
		elseif coroutine.status(t.co) == "dead" then
			table.remove(running, i)
		end
	end
end

function M.active(): boolean
	return #running > 0
end

function M.running(name: string): boolean
	for _, t in ipairs(running) do
		if t.name == name then
			return true
		end
	end
	return false
end

return M
```

```lua
-- file: pixel-shift/engine/capture.luau
--!nonstrict
-- grim capture of one bar strip -> Rgb8 with the bar's long axis horizontal.

local ppm = require("../core/ppm")
local tasks = require("./tasks")

local M = {}
local counter = 0

local function tmpPath(): string
	counter += 1
	local dir = noctalia.getenv("XDG_RUNTIME_DIR")
	if dir == nil or dir == "" then
		dir = noctalia.pluginDataDir()
	end
	return `{dir}/pixel-shift-{counter}.ppm`
end

function M.available(): boolean
	return noctalia.commandExists("grim")
end

-- Must run inside a task. Returns an Rgb8, or nil and an error message.
function M.grab(geometry: string, transpose: boolean)
	local path = tmpPath()
	local res = tasks.await(function(done)
		if not noctalia.runAsync({ "grim", "-t", "ppm", "-g", geometry, path }, done, 5000) then
			done(nil)
		end
	end)
	if not res or res.exitCode ~= 0 or res.timedOut then
		noctalia.removeFile(path)
		return nil, (res and res.stderr ~= "" and res.stderr) or "grim did not run"
	end
	local data, err = tasks.await(function(done)
		if not noctalia.readFileAsync(path, done) then
			done(noctalia.readFile(path))
		end
	end)
	noctalia.removeFile(path)
	if not data then
		return nil, err or "capture unreadable"
	end
	local img, perr = ppm.parse(data)
	if not img then
		return nil, perr
	end
	if transpose then
		img = ppm.transpose(img)
	end
	return img
end

return M
```

```lua
-- file: pixel-shift/engine/store.luau
--!nonstrict
-- Persistence in the plugin data dir: JSON documents and binary blobs,
-- written atomically (temp file + rename), plus rendered lab images.

local M = {}

function M.dir(): string?
	local d = noctalia.pluginDataDir()
	return d
end

local function path(name: string): string?
	local d = M.dir()
	return if d then d .. "/" .. name else nil
end

function M.read(name: string): string?
	local p = path(name)
	if not p then
		return nil
	end
	local s = noctalia.readFile(p)
	return s
end

function M.write(name: string, data: string): boolean
	local p = path(name)
	if not p or not noctalia.writeFile(p .. ".tmp", data) then
		return false
	end
	local ok = noctalia.renameFile(p .. ".tmp", p)
	return ok
end

function M.readJson(name: string)
	local s = M.read(name)
	if not s then
		return nil
	end
	local v = noctalia.json.decode(s)
	return v
end

function M.writeJson(name: string, value): boolean
	local s = noctalia.json.encode(value, true)
	return s ~= nil and M.write(name, s)
end

function M.remove(name: string)
	local p = path(name)
	if p then
		noctalia.removeFile(p)
	end
end

-- A new file name per render so ui.image never shows a cached old image;
-- the previous render of the same slot is deleted.
local renders = {}
local counter = 0
function M.writeImage(slot: string, bytes: string): string?
	local d = M.dir()
	if not d then
		return nil
	end
	noctalia.mkdirAll(d .. "/render")
	counter += 1
	local name = `{d}/render/{slot}-{os.time()}-{counter}.bmp`
	if not noctalia.writeFile(name, bytes) then
		return nil
	end
	if renders[slot] then
		noctalia.removeFile(renders[slot])
	end
	renders[slot] = name
	return name
end

function M.cleanRenders()
	local d = M.dir()
	if not d then
		return
	end
	local files = noctalia.listDir(d .. "/render")
	for _, f in ipairs(files or {}) do
		noctalia.removeFile(if string.sub(f, 1, 1) == "/" then f else d .. "/render/" .. f)
	end
end

return M
```

```lua
-- file: pixel-shift/engine/vertical.luau
--!nonstrict
-- Opt-in vertical shift: an override file in the Noctalia config dir trades
-- margin for thickness, so the bar content moves while the reserved space
-- (and therefore every window) stays where it is.

local util = require("../core/util")

local M = {}
M.FILE = "zz-pixel-shift.toml"

function M.path(): string
	return util.configDir(noctalia.getenv) .. "/" .. M.FILE
end

function M.active(): boolean
	return noctalia.fileExists(M.path())
end

local function reload()
	noctalia.runAsync({ "noctalia", "msg", "config-reload" })
end

-- base = {bar, margin, thickness}: the user's own values, read before the
-- override existed. v = content offset in logical px.
function M.apply(base, v: number): boolean
	if v <= 0 then
		return M.clear()
	end
	local ok = noctalia.writeFile(M.path(), util.verticalToml(base.bar, base.margin + 2 * v, base.thickness - 2 * v))
	if ok then
		reload()
	end
	return ok
end

function M.clear(): boolean
	if M.active() then
		noctalia.removeFile(M.path())
		reload()
	end
	return true
end

function M.effective(base, v: number): boolean
	return noctalia.getSetting(`bar.{base.bar}.margin_edge`) == base.margin + 2 * v
end

return M
```

- [ ] **Step 2: Load check**

Run: `noctalia msg config-reload; sleep 2; grep -n "pixel-shift" ~/.cache/noctalia/noctalia.log | tail -5`
Expected: no Luau errors for `spacer.luau` (the engine is still the stub, so spacers announce and nothing answers yet).

- [ ] **Step 3: Commit**

```bash
git add pixel-shift/spacer.luau pixel-shift/engine
git commit -m "feat: spacer widget and engine helpers"
```

### Task 18: `engine/labmodel` — lab images and model data

**Files:**
- Create: `pixel-shift/engine/labmodel.luau`

**Interfaces:**
- Consumes: `simulate.evaluate`, `render.*`, `hotspots.find`, `optimize.curve/pick/lambdaFromSlider`, `store.writeImage`, `bmp.encode`, `color.glowRamp`.
- Produces: `build(O, ui, ctx) -> data` where
  - `O = {layout, layers, layersId, base, lastCapture?, variance?, rref, acc?, info = {width, thickness}, approximate}`
  - `ui = {view = "bar"|"ghost"|"risk", mode = "none"|"strategy", hotspot = n}`
  - `ctx = {primary, profile, preview, active, previewing, result?, allowVertical, lambdaT, maxShift, stepMinutes, canRevert}`
  - `data = {glow, info, exposure = {n, hours}, score = {none, strategy}, approximate, overview = {left, right, w, h, pins = {{n, row, x, selected}}}, inspector = {none, strategy, w, h, zoom, n}, legend, hotspots = {{n, side, x0, x1, cause, peak}}, curve? = {h, v?, budgets, pick, pickScore}, chips = {{slot, px}}, vertical, stepMinutes, manual = {{slot, value}}, idle = {slot...}, previewing, canRevert, status? = {at, evals, seconds}}`

- [ ] **Step 1: Write the module**

```lua
-- file: pixel-shift/engine/labmodel.luau
--!nonstrict
-- Builds everything the lab shows for one output: evaluations (cached per
-- strategy), the rendered images, hotspots and curve data. Text is left to
-- the lab; this module only produces numbers, enums and image paths.

local image = require("../core/image")
local color = require("../core/color")
local render = require("../core/render")
local bmp = require("../core/bmp")
local hotspots = require("../core/hotspots")
local simulate = require("../core/simulate")
local optimize = require("../core/optimize")
local util = require("../core/util")
local wear = require("../core/wear")
local store = require("./store")

local M = {}

M.OVERVIEW_W = 860
M.INSPECT_W = 560
M.INSPECT_MAX_H = 170

local function hex(c)
	return string.format("#%02x%02x%02x", c[1], c[2], c[3])
end

function M.evaluate(O, strategy)
	O.evalCache = O.evalCache or {}
	O.evalOrder = O.evalOrder or {}
	local key = `{O.layersId}|{util.stableEncode(strategy.ranges)}|{strategy.vertical or 0}`
	local hit = O.evalCache[key]
	if hit then
		return hit
	end
	local ev = simulate.evaluate(O.layers, O.layout, strategy, O.rref)
	O.evalCache[key] = ev
	table.insert(O.evalOrder, key)
	if #O.evalOrder > 6 then
		O.evalCache[table.remove(O.evalOrder, 1)] = nil
	end
	return ev
end

-- Label key for a spacer: the side of the group it moves, and for groups
-- moved by two spacers (the centre) which side the spacer sits on.
function M.slotLabel(layout, slot): string
	for _, g in ipairs(layout.groups) do
		local f = g.factors[slot]
		if f then
			local count = 0
			for _ in pairs(g.factors) do
				count += 1
			end
			local side = util.side((g.own0 + g.own1) / 2, layout.w)
			if count > 1 then
				return if f > 0 then "center_l" else "center_r"
			end
			return side
		end
	end
	return "unknown"
end

local function sortedSlots(layout)
	local list = {}
	for slot in pairs(layout.slots) do
		table.insert(list, slot)
	end
	table.sort(list)
	return list
end

function M.build(O, ui, ctx)
	local layout = O.layout
	local y0, y1 = layout.scoreRows[1], layout.scoreRows[2]
	local none = { ranges = {}, vertical = 0 }
	local evNone = M.evaluate(O, none)
	local evStrat = M.evaluate(O, ctx.preview)
	local eRef = image.percentile(evNone.E, 0.998, y0, y1)
	local rTop = image.percentile(evNone.R, 0.999, y0, y1)
	local ramp = color.glowRamp(ctx.primary)
	local glow = hex(ramp[205])

	local function view(ev)
		if ui.view == "risk" then
			return render.riskView(image.luma(O.base), ev.R, rTop, color.riskRamp(ctx.primary))
		elseif ui.view == "bar" then
			return O.lastCapture or render.fromLinear(O.base)
		end
		return render.ghostView(ev.E, ev.R, eRef, rTop, ramp)
	end
	local fullNone, fullStrat = view(evNone), view(evStrat)
	local shown = if ui.mode == "none" then fullNone else fullStrat

	local spots = hotspots.find({
		R = evStrat.R,
		dw = O.layers.dw,
		wWhite = wear.white(wear.profile(ctx.profile)),
		variance = O.variance,
		layout = layout,
		rref = O.rref,
		strategy = ctx.preview,
	})
	local selected = math.clamp(ui.hotspot or 1, 1, math.max(#spots, 1))
	local sel = spots[selected]

	-- inspector region: centred on the selected hotspot (or the bar centre)
	local zoom = math.clamp(M.INSPECT_MAX_H // layout.h, 1, 4)
	local regionW = M.INSPECT_W // zoom
	local cx = if sel then (sel.x0 + sel.x1) // 2 else layout.w // 2
	local rx0 = math.clamp(cx - regionW // 2, 0, math.max(layout.w - regionW, 0))
	local rx1 = math.min(rx0 + regionW, layout.w)

	-- overview halves with the inspected region framed
	local half = layout.w // 2
	local framed = render.zoom(shown, 0, shown.w, 0, shown.h, 1)
	render.frame(framed, rx0, rx1, ramp[230])
	local left, right = render.halves(framed, M.OVERVIEW_W)
	local scale = M.OVERVIEW_W / half
	local pins = {}
	for i, s in ipairs(spots) do
		local x = (s.x0 + s.x1) / 2
		local row = if x < half then 1 else 2
		table.insert(pins, { n = i, row = row, x = (x - (if row == 2 then half else 0)) * scale, selected = i == selected })
	end

	local data = {
		glow = glow,
		info = O.info,
		exposure = { n = if O.acc then O.acc.n else 0, hours = if O.acc and O.acc.n > 1 then (O.acc.last - O.acc.first) / 3600 else 0 },
		score = { none = evNone.score, strategy = evStrat.score },
		approximate = O.approximate,
		overview = {
			left = store.writeImage("overview-l", bmp.encode(left)),
			right = store.writeImage("overview-r", bmp.encode(right)),
			w = M.OVERVIEW_W,
			h = left.h,
			pins = pins,
		},
		inspector = {
			none = store.writeImage("inspect-none", bmp.encode(render.zoom(fullNone, rx0, rx1, 0, layout.h, zoom))),
			strategy = store.writeImage("inspect-strategy", bmp.encode(render.zoom(fullStrat, rx0, rx1, 0, layout.h, zoom))),
			w = (rx1 - rx0) * zoom,
			h = layout.h * zoom,
			zoom = zoom,
			n = if sel then selected else nil,
		},
		legend = store.writeImage("legend", bmp.encode(render.legend(ramp, 120, 8))),
		hotspots = {},
		chips = {},
		manual = {},
		idle = {},
		vertical = ctx.preview.vertical or 0,
		stepMinutes = ctx.stepMinutes,
		maxShift = ctx.maxShift,
		previewing = ctx.previewing,
		canRevert = ctx.canRevert,
	}
	for i, s in ipairs(spots) do
		data.hotspots[i] = { n = i, side = s.side, x0 = s.x0, x1 = s.x1, cause = s.cause, peak = s.peak }
	end
	for _, slot in ipairs(sortedSlots(layout)) do
		local label = M.slotLabel(layout, slot)
		if layout.slots[slot].moves then
			local px = ctx.preview.ranges[slot] or 0
			table.insert(data.chips, { slot = label, px = px })
			table.insert(data.manual, { id = slot, slot = label, value = px })
		else
			table.insert(data.idle, label)
		end
	end
	if ctx.result then
		local r = ctx.result
		local c = optimize.curve(r.entries, r.budgets)
		local top = math.max(evNone.score, 1)
		local h, v = {}, {}
		for i = 1, #r.budgets do
			h[i] = math.clamp((c.h[i] or top) / (top * 1.05), 0, 1)
			if c.v[i] then
				v[i] = math.clamp(c.v[i] / (top * 1.05), 0, 1)
			end
		end
		local pick = optimize.pick(r.entries, optimize.lambdaFromSlider(ctx.lambdaT), ctx.allowVertical and r.allowVertical)
		local pickIndex = nil
		for i, B in ipairs(r.budgets) do
			if pick and pick.B == B then
				pickIndex = i
			end
		end
		data.curve = {
			h = h,
			v = if #v == #r.budgets then v else nil,
			budgets = r.budgets,
			pick = pickIndex,
			pickScore = pick and pick.score or nil,
			pickLambdaT = ctx.lambdaT,
		}
		data.status = { at = r.at, evals = r.evals, seconds = r.seconds }
	end
	return data
end

return M
```

- [ ] **Step 2: Commit** (exercised end-to-end in Task 21)

```bash
git add pixel-shift/engine/labmodel.luau
git commit -m "feat: lab model builder"
```

### Task 19: Engine service

**Files:**
- Replace: `pixel-shift/engine.luau`

**Interfaces:**
- Consumes: every core module, `engine/*` helpers, state keys from Task 17.
- Produces: IPC events `pause`, `resume`, `toggle`, `rescan`, `optimize`, `lab`; lab commands `view`, `mode`, `hotspot`, `output`, `rescan`, `optimize`, `cancel`, `auto`, `lambda`, `range`, `verticalRange`, `allowVertical`, `apply`, `revert`, `toggle`, `open`, `openBarSettings`.
- Persistent files in the data dir: `state.json`, `layout-<out>.json`, `scan-<out>.bin`, `exposure-<out>.bin`, `render/*.bmp`.

- [ ] **Step 1: Write the engine**

```lua
-- file: pixel-shift/engine.luau
--!nonstrict
-- Pixel Shift engine (service). Owns all state: the spacer registry, one
-- record per output (scan, exposure, optimiser result), the player that turns
-- the active strategy into spacer widths, the vertical override, and the lab.

local util = require("./core/util")
local image = require("./core/image")
local wear = require("./core/wear")
local risk = require("./core/risk")
local layoutMod = require("./core/layout")
local scanstore = require("./core/scanstore")
local exposure = require("./core/exposure")
local optimize = require("./core/optimize")
local schedule = require("./core/schedule")
local tasks = require("./engine/tasks")
local capture = require("./engine/capture")
local store = require("./engine/store")
local vertical = require("./engine/vertical")
local labmodel = require("./engine/labmodel")

local PROBE = 8 -- logical px each spacer is widened by while measuring
local SETTLE_MS = 150 -- wait after the spacers acknowledged before capturing
local STALE = 120 -- s without a hello before a spacer is dropped
local MIN_SAMPLES = 6 -- exposure samples before they replace the scan
local OPT_SLICE_MS = 6
local RETRY_S = 600

-- persisted preferences and per-output records -------------------------------
local saved = store.readJson("state.json") or {}
if type(saved) ~= "table" or saved.version ~= 1 then
	saved = { version = 1 }
end
saved.outputs = saved.outputs or {}
saved.lambdaT = saved.lambdaT or optimize.sliderFromLambda(optimize.LAMBDA_DEFAULT)
if saved.auto == nil then
	saved.auto = true
end
saved.allowVertical = saved.allowVertical == true
saved.paused = saved.paused == true

local spacers = {} -- id -> {output, vertical, t}
local outputs = {} -- name -> O
local widths = {} -- id -> last published width
local forced = nil -- id -> width while a scan measures
local seq = 0
local ui = { output = nil, view = "ghost", mode = "strategy", hotspot = 1 }
local status = { kind = "idle" }
local labOpen, labDirty = false, true
local optimizer = nil -- {name, opt, started, allowVertical}
local spacerChangedAt = os.time()
local fingerprintDue = true
local lastFingerprint, lastSlow, lastVertical = 0, 0, -1
local verticalCheckAt = nil
local errors = {}
local lastCmd = nil

local function setting(key: string, default)
	local v = noctalia.getConfig(key)
	if v == nil then
		return default
	end
	return v
end

local function profileName(): string
	return setting("panel_profile", "generic")
end

local function persist()
	store.writeJson("state.json", saved)
end

local function setStatus(st)
	status = st
	labDirty = true
end

local function fileName(kind: string, name: string): string
	return kind .. "-" .. string.gsub(name, "[^%w%-]", "_")
end

-- spacers --------------------------------------------------------------------
local function spacersOn(name: string)
	local ids = {}
	for id, info in pairs(spacers) do
		if info.output == name then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

local function publishKnown()
	local known = {}
	for id, info in pairs(spacers) do
		known[id] = info.output
	end
	noctalia.state.set("spacers:known", known)
end

-- bar and outputs --------------------------------------------------------------
local function barInfo()
	local order = noctalia.getSetting("bar.order")
	local name = (type(order) == "table" and order[1]) or "main"
	local prefix = "bar." .. name .. "."
	local thickness = noctalia.getSetting(prefix .. "thickness") or 34
	local margin = noctalia.getSetting(prefix .. "margin_edge") or 0
	local base = saved.verticalBase
	if base and vertical.active() then
		thickness, margin = base.thickness, base.margin
	end
	local barScale = noctalia.getSetting(prefix .. "scale") or 1
	return {
		name = name,
		position = noctalia.getSetting(prefix .. "position") or "top",
		rawThickness = thickness,
		thickness = math.floor(thickness * barScale + 0.5),
		margin = margin,
		enabled = noctalia.getSetting(prefix .. "enabled") ~= false,
		layout = {
			noctalia.getSetting(prefix .. "start"),
			noctalia.getSetting(prefix .. "center"),
			noctalia.getSetting(prefix .. "end"),
			noctalia.getSetting(prefix .. "widget_spacing"),
			noctalia.getSetting(prefix .. "padding"),
			noctalia.getSetting(prefix .. "font_family"),
			noctalia.getSetting(prefix .. "font_scale"),
			barScale,
		},
	}
end

local function outputInfo(name: string)
	for _, o in ipairs(noctalia.outputs()) do
		if o.name == name then
			return o
		end
	end
	return nil
end

local function fingerprintFor(name: string, bar, out): string
	return util.fingerprint({
		geo = util.captureGeometry(out, bar).geometry,
		scale = out.scale,
		pos = bar.position,
		thickness = bar.thickness,
		layout = bar.layout,
		spacers = spacersOn(name),
	})
end

local function newOutput(name: string)
	return {
		name = name,
		fp = nil,
		info = nil,
		layout = nil,
		base = nil,
		bg = nil,
		baseL = nil,
		scanLayers = {},
		acc = nil,
		layers = nil,
		layersId = 0,
		rref = risk.reference(wear.profile(profileName())),
		result = nil,
		preview = nil,
		approximate = false,
		needsScan = false,
		needsOptimize = false,
		retryAt = 0,
		lastSample = os.time(),
		mismatches = 0,
		lastCapture = nil,
		variance = nil,
	}
end

local function rebuildLayers(O)
	local key = profileName()
	local p = wear.profile(key)
	O.rref = risk.reference(p)
	if not O.scanLayers[key] then
		O.scanLayers[key] = layoutMod.layers(p, O.base, O.bg)
	end
	if O.acc and O.acc.n >= MIN_SAMPLES then
		O.layers = exposure.layers(O.acc, key, O.scanLayers[key], O.layout)
		O.variance = exposure.variance(O.acc)
	else
		O.layers = O.scanLayers[key]
		O.variance = nil
	end
	O.layersId += 1
	O.evalCache, O.evalOrder = nil, nil
	labDirty = true
end

-- Restore a saved scan when the fingerprint still matches.
local function restore(O, fp: string): boolean
	local meta = saved.outputs[O.name]
	if not meta or meta.fp ~= fp then
		return false
	end
	local l = store.readJson(fileName("layout", O.name) .. ".json")
	local base, bg = scanstore.decode(store.read(fileName("scan", O.name) .. ".bin"))
	if type(l) ~= "table" or type(l.groups) ~= "table" or not base or base.w ~= l.w or base.h ~= l.h then
		return false
	end
	O.layout, O.base, O.bg, O.baseL = l, base, bg, image.luma(base)
	O.info = meta.info
	O.acc = exposure.deserialize(store.read(fileName("exposure", O.name) .. ".bin"))
	if O.acc and (O.acc.w ~= base.w or O.acc.h ~= base.h) then
		O.acc = nil
	end
	O.acc = O.acc or exposure.new(base.w, base.h)
	O.result = meta.result
	O.approximate = meta.approximate == true
	O.fp = fp
	rebuildLayers(O)
	return true
end

-- strategies -------------------------------------------------------------------
local function activeStrategy(name: string)
	local meta = saved.outputs[name]
	return (meta and meta.strategy) or { ranges = {}, vertical = 0 }
end

local function applyStrategy(name: string, strategy, record: boolean?)
	local meta = saved.outputs[name] or {}
	saved.outputs[name] = meta
	if record ~= false and meta.strategy then
		meta.history = meta.history or {}
		table.insert(meta.history, 1, meta.strategy)
		while #meta.history > 3 do
			table.remove(meta.history)
		end
	end
	meta.strategy = { ranges = table.clone(strategy.ranges), vertical = strategy.vertical or 0 }
	persist()
	labDirty = true
end

local function allowVerticalNow(): boolean
	return saved.allowVertical and saved.verticalBase ~= nil and not errors.vertical
end

local function previewFromLambda(name: string)
	local O = outputs[name]
	if not O or not O.result then
		return
	end
	local e = optimize.pick(O.result.entries, optimize.lambdaFromSlider(saved.lambdaT), allowVerticalNow() and O.result.allowVertical)
	if e then
		O.preview = { ranges = table.clone(e.ranges), vertical = e.V }
	end
end

-- player -----------------------------------------------------------------------
local function computeWidths(now: number)
	local out = {}
	local base = setting("step_minutes", 4)
	for name in pairs(outputs) do
		local ids = spacersOn(name)
		local offs = if saved.paused then {} else schedule.offsets(activeStrategy(name), ids, now, base)
		for _, id in ipairs(ids) do
			out[id] = offs[id] or 0
		end
	end
	for id in pairs(spacers) do
		if out[id] == nil then
			out[id] = 0
		end
	end
	if forced then
		for id, w in pairs(forced) do
			out[id] = w
		end
	end
	return out
end

local function publishWidths(force: boolean?)
	local w = computeWidths(os.time())
	local changed = force == true
	for id, v in pairs(w) do
		if widths[id] ~= v then
			changed = true
		end
	end
	if not changed then
		return
	end
	seq += 1
	widths = w
	local msg = { seq = seq }
	for id, v in pairs(w) do
		msg[id] = v
	end
	noctalia.state.set("offsets", msg)
end

local function acked(ids): boolean
	for _, id in ipairs(ids) do
		local a = noctalia.state.get("ack:" .. id)
		if type(a) ~= "number" or a < seq then
			return false
		end
	end
	return true
end

local function playVertical(now: number)
	if not allowVerticalNow() or saved.paused then
		if vertical.active() then
			vertical.clear()
		end
		lastVertical = 0
		return
	end
	local V = 0
	for name in pairs(outputs) do
		V = math.max(V, activeStrategy(name).vertical or 0)
	end
	local v = schedule.vertical(V, now)
	if v ~= lastVertical then
		lastVertical = v
		vertical.apply(saved.verticalBase, v)
		verticalCheckAt = if v > 0 then now + 5 else nil
	elseif verticalCheckAt and now >= verticalCheckAt then
		verticalCheckAt = nil
		if not vertical.effective(saved.verticalBase, v) then
			errors.vertical = true
			vertical.clear()
			for _, O in pairs(outputs) do
				O.needsOptimize = true
			end
			labDirty = true
		end
	end
end

-- measurement ------------------------------------------------------------------
local function fail(name: string, message: string?)
	local O = outputs[name]
	forced = nil
	publishWidths(true)
	if O then
		O.needsScan = false
		O.retryAt = os.time() + RETRY_S
	end
	errors.scan = message or "capture failed"
	noctalia.log("pixel-shift: scan failed on " .. name .. ": " .. tostring(message))
	setStatus({ kind = "error", message = errors.scan })
end

local function scanTask(name: string)
	tasks.spawn("scan:" .. name, function()
		local O = outputs[name]
		local out, bar = outputInfo(name), barInfo()
		local ids = spacersOn(name)
		if not O or not out or not bar.enabled or #ids == 0 then
			if O then
				O.needsScan = false
			end
			return
		end
		setStatus({ kind = "scanning", output = name })
		local verticalWas = vertical.active()
		if verticalWas then
			vertical.clear()
			tasks.sleep(500)
		end
		local geom = util.captureGeometry(out, bar)
		local zero = {}
		for _, id in ipairs(ids) do
			zero[id] = 0
		end
		local function settle(map)
			forced = map
			publishWidths(true)
			tasks.waitFor(function()
				return acked(ids)
			end, 2000)
			tasks.sleep(SETTLE_MS)
		end
		local function grab()
			return capture.grab(geom.geometry, geom.transpose)
		end

		settle(zero)
		local baseA, err = grab()
		if not baseA then
			return fail(name, err)
		end
		local probes = {}
		for _, id in ipairs(ids) do
			local m = table.clone(zero)
			m[id] = PROBE
			settle(m)
			local img, perr = grab()
			if not img then
				return fail(name, perr)
			end
			probes[id] = img
		end
		local all = {}
		for _, id in ipairs(ids) do
			all[id] = PROBE
		end
		settle(all)
		local allImg = grab()
		settle(zero)
		local baseB = grab()
		forced = nil
		publishWidths(true)
		if verticalWas then
			lastVertical = -1
		end
		if not allImg or not baseB then
			return fail(name, "capture failed")
		end

		local barRows, scoreRows = util.rowLayout(geom.flipped, baseA.h, geom.barPx)
		local lin = wear.linearFromRgb8(baseA)
		local baseL = image.luma(lin)
		local probeL = {}
		for id, img in pairs(probes) do
			probeL[id] = image.luma(wear.linearFromRgb8(img))
		end
		local l, diff = layoutMod.build({
			base = baseL,
			baseB = image.luma(wear.linearFromRgb8(baseB)),
			probes = probeL,
			probePx = PROBE,
			scale = geom.scale,
			barRows = barRows,
			scoreRows = scoreRows,
			vDir = geom.vDir,
		})
		local bg = layoutMod.background(lin, l, diff)
		local verr = layoutMod.verify(l, baseL, image.luma(bg), image.luma(wear.linearFromRgb8(allImg)))

		O.layout, O.base, O.bg, O.baseL = l, lin, bg, baseL
		O.scanLayers = {}
		O.approximate = verr > layoutMod.VERIFY_LIMIT
		O.lastCapture = baseA
		O.info = { width = out.width, thickness = bar.thickness, scale = out.scale }
		local fp = fingerprintFor(name, bar, out)
		local meta = saved.outputs[name] or {}
		saved.outputs[name] = meta
		if meta.fp ~= fp or not O.acc or O.acc.w ~= lin.w or O.acc.h ~= lin.h then
			O.acc = exposure.new(lin.w, lin.h)
			store.remove(fileName("exposure", name) .. ".bin")
			meta.result = nil
		end
		O.fp = fp
		meta.fp = fp
		meta.info = O.info
		meta.approximate = O.approximate
		O.result = meta.result
		store.writeJson(fileName("layout", name) .. ".json", l)
		store.write(fileName("scan", name) .. ".bin", scanstore.encode(lin, bg))
		persist()
		errors.scan = nil
		rebuildLayers(O)
		O.needsScan = false
		O.needsOptimize = O.result == nil
		setStatus({ kind = "idle" })
	end)
end

local function locked(): boolean
	local sid = noctalia.getenv("XDG_SESSION_ID")
	if not sid or sid == "" or not noctalia.commandExists("loginctl") then
		return false
	end
	local res = tasks.await(function(done)
		if not noctalia.runAsync({ "loginctl", "show-session", sid, "-p", "LockedHint", "--value" }, done, 3000) then
			done(nil)
		end
	end)
	return res ~= nil and res.exitCode == 0 and string.find(res.stdout, "yes", 1, true) ~= nil
end

local function sampleTask(name: string)
	tasks.spawn("sample:" .. name, function()
		local O = outputs[name]
		if not O or not O.layout then
			return
		end
		O.lastSample = os.time()
		if locked() then
			return
		end
		local out, bar = outputInfo(name), barInfo()
		if not out then
			return
		end
		local geom = util.captureGeometry(out, bar)
		local img = capture.grab(geom.geometry, geom.transpose)
		if not img or exposure.isBlank(img) then
			return
		end
		if img.w ~= O.layout.w or img.h ~= O.layout.h then
			O.needsScan = true
			return
		end
		local now = os.time()
		local offs = if saved.paused then {} else schedule.offsets(activeStrategy(name), spacersOn(name), now, setting("step_minutes", 4))
		local vRows = if vertical.active() and lastVertical > 0 then math.floor(lastVertical * O.layout.scale + 0.5) else 0
		local back = exposure.unshift(wear.linearFromRgb8(img), O.layout, util.displacements(O.layout, offs), vRows)
		if not exposure.matchesBaseline(image.luma(back), O.baseL, O.layout) then
			O.mismatches += 1
			if O.mismatches >= 3 then
				O.mismatches = 0
				O.needsScan = true
			end
			return
		end
		O.mismatches = 0
		O.lastCapture = img
		exposure.add(O.acc, back, now)
		store.write(fileName("exposure", name) .. ".bin", exposure.serialize(O.acc))
		if O.acc.n == MIN_SAMPLES or (O.acc.n > MIN_SAMPLES and O.acc.n % 12 == 0) then
			rebuildLayers(O)
		end
		labDirty = true
	end)
end

-- optimiser --------------------------------------------------------------------
local function startOptimize(name: string)
	local O = outputs[name]
	if not O or not O.layers then
		return
	end
	local maxV = if allowVerticalNow() then 2 else 0
	optimizer = {
		name = name,
		started = os.clock(),
		allowVertical = maxV > 0,
		opt = optimize.new({ layers = O.layers, layout = O.layout, rref = O.rref, maxShift = setting("max_shift", 16), maxV = maxV }),
	}
	O.needsOptimize = false
	setStatus({ kind = "optimizing", output = name, progress = 0 })
end

local function finishOptimize()
	local run = optimizer
	optimizer = nil
	local O = outputs[run.name]
	if run.opt.error then
		noctalia.log("pixel-shift: optimiser error: " .. run.opt.error)
		setStatus({ kind = "error", message = run.opt.error })
		return
	end
	if not O then
		return setStatus({ kind = "idle" })
	end
	O.result = {
		entries = run.opt.entries,
		budgets = run.opt.budgets,
		evals = run.opt.evals,
		at = os.time(),
		seconds = os.clock() - run.started,
		allowVertical = run.allowVertical,
	}
	local meta = saved.outputs[run.name] or {}
	saved.outputs[run.name] = meta
	meta.result = O.result
	if saved.auto then
		local e = optimize.pick(O.result.entries, optimize.lambdaFromSlider(saved.lambdaT), run.allowVertical)
		if e then
			applyStrategy(run.name, { ranges = e.ranges, vertical = e.V })
		end
	end
	O.preview = nil
	persist()
	setStatus({ kind = "idle" })
end

-- output bookkeeping -------------------------------------------------------------
local function refreshOutputs()
	for _, info in pairs(spacers) do
		if info.output ~= "" and not outputs[info.output] then
			outputs[info.output] = newOutput(info.output)
		end
	end
	for name in pairs(outputs) do
		if #spacersOn(name) == 0 then
			outputs[name] = nil
		end
	end
	local bar = barInfo()
	for name, O in pairs(outputs) do
		local out = outputInfo(name)
		if out then
			local fp = fingerprintFor(name, bar, out)
			if O.fp ~= fp then
				if not restore(O, fp) then
					O.needsScan = true
					O.retryAt = 0
				elseif O.result == nil then
					O.needsOptimize = true
				end
			end
		end
	end
end

-- lab -----------------------------------------------------------------------------
local function renderLab()
	labDirty = false
	local names = {}
	for name in pairs(outputs) do
		table.insert(names, name)
	end
	table.sort(names)
	if ui.output == nil or outputs[ui.output] == nil then
		ui.output = names[1]
	end
	local count = 0
	for _ in pairs(spacers) do
		count += 1
	end
	local st = table.clone(status)
	if optimizer then
		st.progress, st.best = optimizer.opt.progress, optimizer.opt.best
	end
	local model = {
		stamp = noctalia.nowMs(),
		status = st,
		outputs = names,
		ui = table.clone(ui),
		paused = saved.paused,
		auto = saved.auto,
		lambdaT = saved.lambdaT,
		allowVertical = saved.allowVertical,
		verticalError = errors.vertical == true,
		scanError = errors.scan,
		grim = capture.available(),
		spacerCount = count,
	}
	local O = ui.output and outputs[ui.output]
	if O and O.layout and O.layers then
		local meta = saved.outputs[ui.output] or {}
		local active = activeStrategy(ui.output)
		local ok, data = pcall(labmodel.build, O, ui, {
			primary = noctalia.getColor("primary"),
			profile = profileName(),
			preview = O.preview or active,
			active = active,
			previewing = O.preview ~= nil,
			result = O.result,
			allowVertical = allowVerticalNow(),
			lambdaT = saved.lambdaT,
			maxShift = setting("max_shift", 16),
			stepMinutes = setting("step_minutes", 4),
			canRevert = meta.history ~= nil and #meta.history > 0,
		})
		if ok then
			model.data = data
		else
			noctalia.log("pixel-shift: lab render failed: " .. tostring(data))
		end
	end
	noctalia.state.set("lab:model", model)
end

local function setAllowVertical(on: boolean)
	errors.vertical = nil
	if on then
		if not saved.verticalBase then
			local bar = barInfo()
			saved.verticalBase = { bar = bar.name, margin = bar.margin, thickness = bar.rawThickness }
		end
		saved.allowVertical = true
	else
		saved.allowVertical = false
		vertical.clear()
		lastVertical = 0
	end
	persist()
	for _, O in pairs(outputs) do
		O.needsOptimize = true
	end
end

local function setPaused(p: boolean)
	saved.paused = p
	persist()
	noctalia.state.set("paused", p)
	publishWidths(true)
	labDirty = true
end

local function handle(cmd: string, arg)
	local name = ui.output
	local O = name and outputs[name]
	if cmd == "view" or cmd == "mode" then
		ui[cmd] = arg
	elseif cmd == "hotspot" then
		ui.hotspot = tonumber(arg) or 1
	elseif cmd == "output" then
		ui.output, ui.hotspot = arg, 1
	elseif cmd == "rescan" then
		if O then
			O.needsScan, O.retryAt = true, 0
		end
	elseif cmd == "optimize" then
		if O then
			O.needsOptimize = true
		end
	elseif cmd == "cancel" then
		optimizer = nil
		setStatus({ kind = "idle" })
	elseif cmd == "auto" then
		saved.auto = arg == true
		if O then
			O.preview = nil
			if saved.auto then
				previewFromLambda(name)
			end
		end
		persist()
	elseif cmd == "lambda" then
		saved.lambdaT = math.clamp(tonumber(arg) or saved.lambdaT, 0, 1)
		persist()
		if name then
			previewFromLambda(name)
		end
	elseif cmd == "range" and O and type(arg) == "table" then
		local p = O.preview or activeStrategy(name)
		O.preview = { ranges = table.clone(p.ranges), vertical = p.vertical or 0 }
		O.preview.ranges[arg.id] = math.clamp(math.floor(tonumber(arg.value) or 0), 0, setting("max_shift", 16))
	elseif cmd == "verticalRange" and O then
		local p = O.preview or activeStrategy(name)
		O.preview = { ranges = table.clone(p.ranges), vertical = math.clamp(math.floor(tonumber(arg) or 0), 0, 2) }
	elseif cmd == "allowVertical" then
		setAllowVertical(arg == true)
	elseif cmd == "apply" then
		if O and O.preview then
			applyStrategy(name, O.preview)
			O.preview = nil
		end
	elseif cmd == "revert" then
		local meta = name and saved.outputs[name]
		if meta and meta.history and #meta.history > 0 then
			local prev = table.remove(meta.history, 1)
			applyStrategy(name, prev, false)
			if O then
				O.preview = nil
			end
		end
	elseif cmd == "toggle" then
		setPaused(not saved.paused)
	elseif cmd == "pause" or cmd == "resume" then
		setPaused(cmd == "pause")
	elseif cmd == "open" then
		labOpen = arg ~= false
	elseif cmd == "openBarSettings" then
		noctalia.runAsync({ "noctalia", "msg", "settings-open", "bar" })
	end
	labDirty = true
end

-- wiring ----------------------------------------------------------------------------
noctalia.state.watch("spacer:hello", function(v)
	if type(v) ~= "table" or type(v.id) ~= "string" then
		return
	end
	local prev = spacers[v.id]
	spacers[v.id] = { output = v.output or "", vertical = v.vertical == true, t = os.time() }
	if not prev or prev.output ~= spacers[v.id].output then
		spacerChangedAt, fingerprintDue = os.time(), true
		publishKnown()
		publishWidths(true)
	end
end)

noctalia.state.watch("spacer:bye", function(v)
	if type(v) == "table" and spacers[v.id] then
		spacers[v.id] = nil
		spacerChangedAt, fingerprintDue = os.time(), true
		publishKnown()
	end
end)

noctalia.state.watch("lab:cmd", function(c)
	if type(c) ~= "table" or c.seq == nil or c.seq == lastCmd then
		return
	end
	lastCmd = c.seq
	handle(c.cmd, c.arg)
end)

function onIpc(event, payload)
	if event == "pause" or event == "resume" or event == "toggle" or event == "rescan" or event == "optimize" then
		handle(event, payload)
	elseif event == "lab" then
		noctalia.togglePanel("mgeldi/pixel-shift:lab")
	end
end

function onConfigChanged()
	for _, O in pairs(outputs) do
		if O.layout then
			rebuildLayers(O)
			O.needsOptimize = true
		end
	end
end

function onOutputsChanged()
	fingerprintDue = true
end

function onExit(_signal, reason)
	if reason ~= "reload" then
		vertical.clear()
	end
end

function update()
	local now = os.time()
	tasks.tick()
	if optimizer then
		if optimizer.opt:step(OPT_SLICE_MS) then
			finishOptimize()
		else
			labDirty = labDirty or (now ~= lastSlow)
		end
	end
	if now ~= lastSlow then
		lastSlow = now
		local pruned, changed = util.pruneRegistry(spacers, now, STALE)
		if changed then
			spacers = pruned
			spacerChangedAt, fingerprintDue = now, true
			publishKnown()
		end
		if now - spacerChangedAt >= 3 and (fingerprintDue or now - lastFingerprint >= 60) then
			lastFingerprint, fingerprintDue = now, false
			refreshOutputs()
		end
		if not tasks.active() and not optimizer then
			local today = os.date("%Y-%m-%d", now)
			if tonumber(os.date("%H", now)) >= 4 and saved.lastNightly ~= today then
				saved.lastNightly = today
				persist()
				for _, O in pairs(outputs) do
					if O.acc and O.acc.n >= MIN_SAMPLES then
						rebuildLayers(O)
						O.needsOptimize = true
					end
				end
			end
			local every = setting("sample_minutes", 10) * 60
			for name, O in pairs(outputs) do
				if O.needsScan and O.retryAt <= now then
					if capture.available() then
						scanTask(name)
					end
					break
				elseif O.needsOptimize and O.layers then
					startOptimize(name)
					break
				elseif O.layout and now - O.lastSample >= every then
					sampleTask(name)
					break
				end
			end
		end
		if not forced then
			publishWidths(false)
		end
		playVertical(now)
	end
	if labOpen and labDirty and not tasks.active() then
		renderLab()
	end
	noctalia.setUpdateInterval(if optimizer or tasks.active() then 33 else 1000)
end

-- start ---------------------------------------------------------------------------
if vertical.active() and not saved.allowVertical then
	vertical.clear() -- stale file from a crash
end
store.cleanRenders()
noctalia.state.set("paused", saved.paused)
noctalia.state.set("engine:epoch", noctalia.nowMs())
noctalia.setUpdateInterval(250)
```

- [ ] **Step 2: Live smoke test**

Run: `noctalia msg config-reload; sleep 8; grep -n "pixel-shift" ~/.cache/noctalia/noctalia.log | tail -20; ls ~/.local/state/noctalia/plugins/data/mgeldi 2>/dev/null || ls ~/.local/state/noctalia/plugins/data`
Expected: no Luau errors; after ~10 s a `layout-DP-2.json`, `scan-DP-2.bin` and (after the optimiser) `state.json` with a strategy appear in the plugin data dir. The bar twitches once during the scan.

- [ ] **Step 3: Commit**

```bash
git add pixel-shift/engine.luau
git commit -m "feat: engine service (scan, sample, optimise, play)"
```

---

### Task 20: Burn-in Lab panel

**Files:**
- Replace: `pixel-shift/lab.luau`

**Interfaces:**
- Consumes: `lab:model` (engine), translation keys from Task 21.
- Produces: `lab:cmd` messages (see Task 19).

Before writing the panel, invoke the `impeccable` skill and apply its hierarchy, spacing and typography guidance to the approved concept C v5 (the mockups in `.superpowers/brainstorm/*/content/lab-c-v5.html`). The layout below is the baseline; the design pass may only change sizes, spacing, weights and copy, not the structure the user approved.

- [ ] **Step 1: Write the panel**

```lua
-- file: pixel-shift/lab.luau
--!nonstrict
-- Burn-in Lab. Pure presentation: renders the model the engine publishes in
-- "lab:model" and sends every action back through "lab:cmd".

local model = noctalia.state.get("lab:model")
local draft = {} -- slider values while a drag is in progress
local seqN = 0
local render

local function tr(key: string, subst): string
	return noctalia.tr(key, subst)
end

local function send(cmd: string, arg)
	seqN += 1
	noctalia.state.set("lab:cmd", { seq = `lab-{noctalia.nowMs()}-{seqN}`, cmd = cmd, arg = arg })
end

local function round(x: number): number
	return math.floor(x + 0.5)
end

local function muted(t: string, size: number?)
	return ui.label({ text = t, fontSize = size or 12, color = "on_surface_variant" })
end

local function note(t: string, width: number, color: string?)
	return ui.label({ text = t, fontSize = 11, color = color or "on_surface_variant", maxWidth = width, maxLines = 4 })
end

local function chip(t: string)
	return ui.row({ fill = "surface_variant", radius = 999, paddingH = 10, paddingV = 4, align = "center" }, {
		ui.label({ text = t, fontSize = 12, color = "on_surface_variant" }),
	})
end

local function card(children, props)
	props = props or {}
	props.fill = props.fill or "surface_variant"
	props.radius = props.radius or 14
	props.padding = props.padding or 12
	props.gap = props.gap or 8
	return ui.column(props, children)
end

local function segmented(options, current, cmd: string)
	local items = {}
	for _, o in ipairs(options) do
		local on = o.value == current
		table.insert(items, ui.button({
			text = o.label,
			controlSize = "sm",
			variant = if on then "primary" else "ghost",
			selected = on,
			onClick = function()
				send(cmd, o.value)
			end,
		}))
	end
	return ui.row({ fill = "surface_variant", radius = 999, padding = 3, gap = 2, align = "center" }, items)
end

local function pin(n: number, glow: string, selected: boolean)
	local props = {
		width = 20,
		height = 20,
		radius = 10,
		fill = glow,
		align = "center",
		justify = "center",
		onClick = function()
			send("hotspot", n)
		end,
	}
	if selected then
		props.border, props.borderWidth = "on_surface", 2
	end
	return ui.row(props, { ui.label({ text = tostring(n), fontSize = 11, fontWeight = "bold", color = "#15151a" }) })
end

local function tag(t: string, glow: string, soft: boolean?)
	return ui.row({ fill = if soft then "surface" else glow .. "33", radius = 6, paddingH = 6, paddingV = 2 }, {
		ui.label({ text = t, fontSize = 11, color = if soft then "on_surface_variant" else glow }),
	})
end

local function deltaText(d): string
	local n, s = d.score.none, d.score.strategy
	if n <= 0 then
		return "0%"
	end
	return string.format("%+d%%", round((s - n) / n * 100))
end

local function pickName(t: number): string
	if t < 0.2 then
		return "calm"
	elseif t < 0.55 then
		return "balanced"
	elseif t < 0.85 then
		return "strong"
	end
	return "max"
end

-- header -------------------------------------------------------------------------
local function header(m)
	local d = m and m.data
	local items = { ui.label({ text = tr("lab.title"), fontSize = 17, fontWeight = "semibold", color = "on_surface" }) }
	if d and d.info then
		table.insert(items, chip(`{m.ui.output} · {d.info.width}×{d.info.thickness}`))
	end
	if d then
		local e = d.exposure
		table.insert(items, chip(if e.n > 0
			then tr("lab.exposure.some", { count = e.n, hours = string.format("%.1f", e.hours) })
			else tr("lab.exposure.none")))
	end
	table.insert(items, ui.spacer({ flexGrow = 1 }))
	if m and #m.outputs > 1 then
		local opts = {}
		for _, name in ipairs(m.outputs) do
			table.insert(opts, { label = name, value = name })
		end
		table.insert(items, segmented(opts, m.ui.output, "output"))
	end
	if d then
		table.insert(items, segmented({
			{ label = tr("lab.view.bar"), value = "bar" },
			{ label = tr("lab.view.ghost"), value = "ghost" },
			{ label = tr("lab.view.risk"), value = "risk" },
		}, m.ui.view, "view"))
		table.insert(items, segmented({
			{ label = tr("lab.mode.none"), value = "none" },
			{ label = tr("lab.mode.strategy"), value = "strategy" },
		}, m.ui.mode, "mode"))
		table.insert(items, ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("lab.rescan"), onClick = function()
			send("rescan")
		end }))
	end
	table.insert(items, ui.button({ glyph = "close", variant = "ghost", onClick = function()
		panel.close()
	end }))
	return ui.row({ align = "center", gap = 10 }, items)
end

-- overview -----------------------------------------------------------------------
local function pinRow(pins, row: number, width: number, glow: string)
	local list = {}
	for _, p in ipairs(pins) do
		if p.row == row then
			table.insert(list, p)
		end
	end
	table.sort(list, function(a, b)
		return a.x < b.x
	end)
	local children, cursor = {}, 0
	for _, p in ipairs(list) do
		local left = math.clamp(round(p.x - 10), cursor, math.max(cursor, width - 20))
		if left > cursor then
			table.insert(children, ui.box({ width = left - cursor, height = 1 }))
		end
		table.insert(children, pin(p.n, glow, p.selected))
		cursor = left + 20
	end
	return ui.row({ height = 22, width = width, align = "center" }, children)
end

local function overview(d)
	local o = d.overview
	return ui.column({ gap = 4 }, {
		muted(tr("lab.overview"), 11),
		pinRow(o.pins, 1, o.w, d.glow),
		ui.image({ path = o.left, width = o.w, height = o.h, fit = "stretch", radius = 6 }),
		pinRow(o.pins, 2, o.w, d.glow),
		ui.image({ path = o.right, width = o.w, height = o.h, fit = "stretch", radius = 6 }),
	})
end

-- inspector ----------------------------------------------------------------------
local function inspector(d)
	local i = d.inspector
	local spot = i.n and d.hotspots[i.n]
	local title = if spot then tr("hotspot.side." .. spot.side) else tr("lab.inspect_center")
	return ui.column({ gap = 6, width = 560 }, {
		muted(tr("lab.inspect_none", { title = title, zoom = i.zoom }), 11),
		ui.image({ path = i.none, width = i.w, height = i.h, fit = "stretch", radius = 6 }),
		ui.row({ gap = 8, align = "center" }, { muted(tr("lab.inspect_strategy"), 11), tag(deltaText(d), d.glow) }),
		ui.image({ path = i.strategy, width = i.w, height = i.h, fit = "stretch", radius = 6 }),
		note(tr("lab.inspect_note"), 560),
	})
end

-- sidebar ------------------------------------------------------------------------
local function scoreCard(d)
	local items = {
		muted(tr("lab.risk_title")),
		ui.row({ gap = 10, align = "center" }, {
			ui.label({ text = `{round(d.score.none)} → {round(d.score.strategy)}`, fontSize = 30, fontWeight = "bold", color = "on_surface" }),
			tag(deltaText(d), d.glow),
		}),
		ui.row({ gap = 6, align = "center" }, {
			muted(tr("lab.safe"), 11),
			ui.image({ path = d.legend, width = 120, height = 8, fit = "stretch", radius = 4 }),
			muted(tr("lab.risky"), 11),
		}),
	}
	if d.approximate then
		table.insert(items, note(tr("lab.approximate"), 320, "error"))
	end
	for _, slot in ipairs(d.idle) do
		table.insert(items, note(tr("lab.moves_nothing", { slot = tr("slot." .. slot) }), 320, "error"))
	end
	return card(items)
end

local function hotspotList(d, selected: number)
	if #d.hotspots == 0 then
		return card({ muted(tr("lab.no_hotspots")) })
	end
	local rows = {}
	for _, h in ipairs(d.hotspots) do
		local isSel = h.n == selected
		local body = {
			ui.label({
				text = tr("hotspot.range", { side = tr("hotspot.side." .. h.side), x0 = h.x0, x1 = h.x1 }),
				fontSize = 12.5,
				fontWeight = if isSel then "semibold" else "normal",
				color = "on_surface",
			}),
			ui.row({ gap = 6 }, { tag(tr("cause." .. h.cause), d.glow, h.cause == "outside" or h.cause == "dynamic") }),
		}
		if isSel then
			table.insert(body, note(tr("hint." .. h.cause), 290))
		end
		local props = { gap = 9, padding = 8, radius = 10, align = "start", onClick = function()
			send("hotspot", h.n)
		end }
		if isSel then
			props.fill = "surface"
		end
		table.insert(rows, ui.row(props, { pin(h.n, d.glow, false), ui.column({ gap = 3, flexGrow = 1 }, body) }))
	end
	return card(rows, { padding = 6, gap = 2 })
end

-- strategy -----------------------------------------------------------------------
local function statusLine(m, d)
	local st = m.status or {}
	if st.kind == "optimizing" then
		return muted(tr("lab.optimizing", { percent = round((st.progress or 0) * 100) }))
	elseif d.status then
		return muted(tr("lab.optimized", {
			time = noctalia.formatTime(noctalia.timeFormat(), d.status.at),
			count = d.status.evals,
			seconds = string.format("%.1f", d.status.seconds),
		}))
	end
	return muted(tr("lab.not_optimized"))
end

local function curveBlock(m, d)
	local c = d.curve
	local width = 500
	local lambda = draft.lambda or round(m.lambdaT * 100)
	local items = {
		ui.graph({ width = width, height = 110, values = c.h, values2 = c.v, color = "on_surface_variant", color2 = d.glow, lineWidth = 2, fillOpacity = 0.06 }),
	}
	if c.pick then
		local x = (c.pick - 1) / math.max(#c.budgets - 1, 1) * width
		table.insert(items, ui.row({ width = width, height = 16, align = "center" }, {
			ui.box({ width = math.max(round(x) - 6, 0), height = 1 }),
			ui.label({ text = tr("lab.auto_pick_marker", { score = round(c.pickScore or 0) }), fontSize = 11, color = d.glow }),
		}))
	end
	table.insert(items, ui.row({ width = width, gap = 10, align = "center" }, {
		muted(tr("lab.calm"), 11),
		ui.slider({
			min = 0,
			max = 100,
			step = 1,
			value = lambda,
			flexGrow = 1,
			onChange = function(v)
				draft.lambda = tonumber(v)
				render()
			end,
			onDragEnd = function()
				if draft.lambda then
					send("lambda", draft.lambda / 100)
					draft.lambda = nil
				end
			end,
		}),
		muted(tr("lab.max"), 11),
	}))
	return ui.column({ gap = 4, width = width }, items)
end

local function chips(d)
	local items = {}
	for _, c in ipairs(d.chips) do
		table.insert(items, chip(tr("lab.chip_px", { slot = tr("slot." .. c.slot), px = c.px })))
	end
	if d.vertical > 0 then
		table.insert(items, chip(tr("lab.chip_vertical", { px = d.vertical })))
	end
	table.insert(items, chip(tr("lab.chip_step", { minutes = d.stepMinutes })))
	local rowA, rowB = {}, {}
	for i, it in ipairs(items) do
		table.insert(if i <= 3 then rowA else rowB, it)
	end
	return ui.column({ gap = 6 }, { ui.row({ gap = 6 }, rowA), ui.row({ gap = 6 }, rowB) })
end

local function verticalToggle(m)
	local items = {
		ui.row({ gap = 8, align = "center" }, {
			ui.toggle({ checked = m.allowVertical, onChange = function(v)
				send("allowVertical", v == "true")
			end }),
			ui.label({ text = tr("lab.allow_vertical"), fontSize = 12.5, color = "on_surface" }),
		}),
		note(tr("lab.allow_vertical_note"), 330),
	}
	if m.verticalError then
		table.insert(items, note(tr("lab.vertical_error"), 330, "error"))
	end
	return ui.column({ gap = 4 }, items)
end

local function slider(label: string, key: string, value: number, max: number, suffix: string, commit)
	local v = draft[key] or value
	return ui.row({ gap = 10, align = "center" }, {
		ui.label({ text = label, fontSize = 12, color = "on_surface_variant", width = 84 }),
		ui.slider({
			min = 0,
			max = max,
			step = 1,
			value = v,
			flexGrow = 1,
			onChange = function(x)
				draft[key] = tonumber(x)
				render()
			end,
			onDragEnd = function()
				if draft[key] then
					commit(draft[key])
					draft[key] = nil
				end
			end,
		}),
		ui.label({ text = string.format(suffix, v), fontSize = 12, color = "on_surface", width = 48 }),
	})
end

local function manualBlock(m, d)
	local rows = {}
	for _, s in ipairs(d.manual) do
		table.insert(rows, slider(tr("slot." .. s.slot), "range:" .. s.id, s.value, d.maxShift, "%d px", function(x)
			send("range", { id = s.id, value = x })
		end))
	end
	if m.allowVertical then
		table.insert(rows, slider(tr("lab.manual_vertical"), "vertical", d.vertical, 2, "±%d px", function(x)
			send("verticalRange", x)
		end))
	end
	return ui.column({ gap = 8, flexGrow = 1 }, rows)
end

local function strategyCard(m, d)
	local st = m.status or {}
	local head = {
		ui.label({ text = tr("lab.strategy"), fontSize = 13, fontWeight = "semibold", color = "on_surface" }),
		segmented({ { label = tr("lab.auto"), value = true }, { label = tr("lab.manual"), value = false } }, m.auto, "auto"),
		statusLine(m, d),
		ui.spacer({ flexGrow = 1 }),
	}
	if st.kind == "optimizing" then
		table.insert(head, ui.button({ text = tr("lab.cancel"), variant = "ghost", controlSize = "sm", onClick = function()
			send("cancel")
		end }))
	else
		table.insert(head, ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = tr("lab.reoptimize"), onClick = function()
			send("optimize")
		end }))
	end
	if d.canRevert then
		table.insert(head, ui.button({ text = tr("lab.revert"), variant = "ghost", controlSize = "sm", onClick = function()
			send("revert")
		end }))
	end
	table.insert(head, ui.button({ text = tr("lab.apply"), variant = "primary", controlSize = "sm", enabled = d.previewing, onClick = function()
		send("apply")
	end }))

	local body
	if st.kind == "optimizing" then
		local rows = {
			ui.progress({ progress = st.progress or 0, fill = d.glow, track = "surface", height = 6, radius = 3 }),
			note(tr("lab.optimizing_note"), 860),
		}
		if st.best and st.best < 1e9 then
			table.insert(rows, muted(tr("lab.best_so_far", { score = round(st.best) }), 11))
		end
		body = ui.column({ gap = 6 }, rows)
	elseif m.auto and d.curve then
		local t = (draft.lambda or round(m.lambdaT * 100)) / 100
		body = ui.row({ gap = 18, align = "start" }, {
			curveBlock(m, d),
			ui.column({ gap = 8, flexGrow = 1 }, {
				ui.label({ text = tr("lab.pick_title", { name = tr("lab.pick_names." .. pickName(t)) }), fontSize = 12.5, fontWeight = "semibold", color = "on_surface" }),
				note(tr("lab.pick_note"), 330),
				chips(d),
				verticalToggle(m),
				note(tr("lab.reoptimize_note"), 330),
			}),
		})
	elseif m.auto then
		body = muted(tr("lab.not_optimized"))
	else
		body = ui.row({ gap = 18, align = "start" }, { manualBlock(m, d), ui.column({ gap = 8, width = 330 }, { chips(d), verticalToggle(m) }) })
	end
	return card({ ui.row({ gap = 10, align = "center" }, head), body }, { gap = 10 })
end

-- states -------------------------------------------------------------------------
local function onboarding()
	return card({
		ui.label({ text = tr("lab.onboarding.title"), fontSize = 15, fontWeight = "semibold", color = "on_surface" }),
		note(tr("lab.onboarding.body"), 860),
		ui.markdown({ text = tr("lab.onboarding.steps") }),
		ui.row({ gap = 8 }, {
			ui.button({ text = tr("lab.onboarding.open_settings"), variant = "primary", onClick = function()
				send("openBarSettings")
			end }),
		}),
	}, { padding = 16, gap = 10 })
end

local function banner(m)
	if m.paused then
		return card({
			ui.row({ gap = 10, align = "center" }, {
				ui.label({ text = tr("lab.paused"), fontSize = 12, color = "on_surface", flexGrow = 1 }),
				ui.button({ text = tr("lab.resume"), variant = "primary", controlSize = "sm", onClick = function()
					send("resume")
				end }),
			}),
		}, { padding = 10 })
	elseif m.status and m.status.kind == "scanning" then
		return card({ muted(tr("lab.scanning")) }, { padding = 10 })
	elseif m.status and m.status.kind == "error" then
		return card({ note(tr("lab.error", { message = m.status.message or "" }), 860, "error") }, { padding = 10 })
	end
	return nil
end

render = function()
	local m = model
	local children = { header(m) }
	if not m then
		table.insert(children, muted(tr("lab.starting")))
	elseif m.grim == false then
		table.insert(children, card({ note(tr("lab.no_grim"), 860, "error") }))
	elseif (m.spacerCount or 0) == 0 then
		table.insert(children, onboarding())
	else
		local b = banner(m)
		if b then
			table.insert(children, b)
		end
		local d = m.data
		if d then
			table.insert(children, overview(d))
			table.insert(children, ui.row({ gap = 16, align = "start" }, {
				inspector(d),
				ui.column({ gap = 10, flexGrow = 1 }, { scoreCard(d), hotspotList(d, m.ui.hotspot) }),
			}))
			table.insert(children, strategyCard(m, d))
		elseif not b then
			table.insert(children, card({ muted(tr("lab.waiting")) }))
		end
	end
	panel.render(ui.scroll({ flexGrow = 1, gap = 14 }, children))
end

noctalia.state.watch("lab:model", function(v)
	model = v
	render()
end)

function onOpen()
	send("open", true)
	model = noctalia.state.get("lab:model")
	render()
end

function onClose()
	send("open", false)
end
```

- [ ] **Step 2: Open the lab and look at it**

Run: `noctalia msg panel-toggle mgeldi/pixel-shift:lab; sleep 2; grim /tmp/claude-1000/ps-lab.png`
Expected: the concept C layout with real images. Read the screenshot, compare with `lab-c-v5.html`, fix spacing/sizing issues, repeat.

- [ ] **Step 3: Commit**

```bash
git add pixel-shift/lab.luau
git commit -m "feat: Burn-in Lab panel"
```

### Task 21: Control-center tile and translations

**Files:**
- Replace: `pixel-shift/toggle.luau`, `pixel-shift/translations/en.json`

- [ ] **Step 1: Write the files**

```lua
-- file: pixel-shift/toggle.luau
--!nonstrict
-- Control-center tile: pause or resume shifting. Right click opens the lab.

local paused = noctalia.state.get("paused") == true
local seqN = 0

local function render()
	shortcut.setLabel(noctalia.tr(if paused then "toggle.off" else "toggle.on"))
	shortcut.setIcon("arrows-move-horizontal", "player-pause")
	shortcut.setActive(not paused)
	shortcut.setEnabled(true)
end

noctalia.state.watch("paused", function(v)
	paused = v == true
	render()
end)

function onClick()
	seqN += 1
	noctalia.state.set("lab:cmd", { seq = `toggle-{noctalia.nowMs()}-{seqN}`, cmd = "toggle" })
end

function onRightClick()
	noctalia.togglePanel("mgeldi/pixel-shift:lab")
end

render()
```

```json
// -- file: pixel-shift/translations/en.json
{
  "settings": {
    "panel_profile": {
      "label": "Panel type",
      "description": "Which OLED technology your screen uses. Changes how much each colour channel wears.",
      "options": {
        "generic": "Generic OLED (blue wears fastest)",
        "woled": "WOLED (LG panels)",
        "qdoled": "QD-OLED (Samsung panels)"
      }
    },
    "sample_minutes": {
      "label": "Sampling interval (minutes)",
      "description": "How often the bar is captured to learn what it shows over the day."
    },
    "step_minutes": {
      "label": "Step time (minutes)",
      "description": "Time between 1 px moves. Spacers use slightly different multiples so they never move in step."
    },
    "max_shift": {
      "label": "Maximum shift (px)",
      "description": "Upper limit for how far any group may move."
    }
  },
  "lab": {
    "title": "Burn-in Lab",
    "starting": "Starting…",
    "waiting": "Waiting for the first measurement…",
    "rescan": "Measure the bar again",
    "view": { "bar": "Bar", "ghost": "Ghost", "risk": "Risk" },
    "mode": { "none": "No shift", "strategy": "Strategy" },
    "exposure": {
      "none": "Exposure: 1 snapshot",
      "some": "Exposure: {count} samples · {hours} h"
    },
    "overview": "Whole bar · left half / right half",
    "inspect_center": "Bar centre",
    "inspect_none": "{title} · {zoom}× · no shift",
    "inspect_strategy": "With strategy",
    "inspect_note": "Always shows the strategy below. It updates when auto re-optimizes or you move a slider.",
    "risk_title": "Visible burn-in risk",
    "safe": "safe",
    "risky": "risky",
    "approximate": "The measurement was noisy, so these results are approximate. Check the spacer placement and measure again.",
    "moves_nothing": "The {slot} spacer moves nothing. Put it before the widgets it should move.",
    "no_hotspots": "Nothing risky left. Nice bar.",
    "strategy": "Strategy",
    "auto": "Auto",
    "manual": "Manual",
    "apply": "Apply",
    "revert": "Revert",
    "cancel": "Cancel",
    "reoptimize": "Optimize again",
    "optimized": "✓ optimized {time} · {count} strategies · {seconds} s",
    "not_optimized": "Not optimized yet",
    "optimizing": "Optimizing… {percent}%",
    "optimizing_note": "Runs in small slices between frames, so the shell stays responsive.",
    "best_so_far": "best so far {score}",
    "scanning": "Measuring the bar. It twitches for a moment.",
    "calm": "Calm",
    "max": "Max protection",
    "pick_title": "Auto pick: {name}",
    "pick_names": { "calm": "Calm", "balanced": "Balanced", "strong": "Strong", "max": "Maximum" },
    "pick_note": "Beyond this point each extra pixel of movement buys little extra protection.",
    "auto_pick_marker": "▲ auto pick · {score}",
    "chip_px": "{slot} {px} px",
    "chip_vertical": "Vertical ±{px} px",
    "chip_step": "1 px / {minutes} min",
    "allow_vertical": "Allow vertical shift",
    "allow_vertical_note": "Writes its own config file (zz-pixel-shift.toml). Windows keep their size.",
    "vertical_error": "Vertical shift had no effect (a GUI setting overrides it) and was turned off.",
    "reoptimize_note": "Re-optimizes by itself when your widgets or layout change, and every night with the day's samples.",
    "manual_vertical": "Vertical",
    "paused": "Paused: the bar is not shifting.",
    "resume": "Resume",
    "onboarding": {
      "title": "Add Pixel Shift spacers to your bar",
      "body": "Spacers are invisible widgets. Pixel Shift changes their width over the day, which moves the widgets next to them by a few pixels.",
      "steps": "1. Open the bar settings and add the **Pixel Shift** spacer widget.\n2. Put one at the **start of the left section**, one at the **end of the right section**, and one on **each side of the center section**.\n3. Come back here: Pixel Shift measures the bar and finds the best strategy by itself.",
      "open_settings": "Open bar settings"
    },
    "no_grim": "grim is not installed. Pixel Shift needs it to measure the bar.",
    "error": "Measuring failed: {message}"
  },
  "hotspot": {
    "side": { "left": "Left group", "center": "Center group", "right": "Right group" },
    "range": "{side} · {x0}–{x1} px"
  },
  "cause": {
    "outside": "outside the bar",
    "dynamic": "changing content",
    "wide": "solid fill wider than the shift",
    "horizontal": "horizontal edge",
    "bright": "very bright",
    "static": "static detail"
  },
  "hint": {
    "outside": "Not part of the bar, for example a window border. Pixel Shift cannot move it.",
    "dynamic": "This content changes often, so the estimate drops as sampling continues.",
    "wide": "Shifting cannot blur a solid fill this wide. Lower its opacity or use an outline style.",
    "horizontal": "Horizontal shifting never blurs horizontal edges. Allow vertical shift, or soften the edge.",
    "bright": "Very bright pixels wear fastest. Dim this colour or use a thinner font weight.",
    "static": "Stays put even with shifting. A wider range for this group helps."
  },
  "slot": {
    "left": "Left",
    "center": "Center",
    "center_l": "Center ◂",
    "center_r": "Center ▸",
    "right": "Right",
    "unknown": "Spacer"
  },
  "toggle": {
    "on": "Pixel Shift",
    "off": "Pixel Shift paused"
  }
}
```

- [ ] **Step 2: Lint**

Run: `noctalia plugins lint ~/Projects/noctalia-pixel-shift/pixel-shift`
Expected: no errors (declared settings are read in code).

- [ ] **Step 3: Commit**

```bash
git add pixel-shift/toggle.luau pixel-shift/translations/en.json
git commit -m "feat: control-center tile and English strings"
```

### Task 22: Live end-to-end verification (both outputs)

**Files:** fixes wherever they are needed; notes in `docs/verification.md`.

- [ ] **Step 1: Suite and lint** — `tools/test.sh` (all green) and `noctalia plugins lint pixel-shift`.
- [ ] **Step 2: Scan** — reload Noctalia, watch the log, confirm `layout-DP-2.json`/`layout-DP-3.json` in the data dir, groups and factors plausible (start +1, centre ±0.5, end −1 at scale 1; ×1.5 on DP-3).
- [ ] **Step 3: Optimiser** — time from scan to applied strategy; `state.json` holds the strategy; spacers move (grim captures a few minutes apart show 1 px steps).
- [ ] **Step 4: Lab** — open, switch views/modes/hotspots/outputs, drag the slider, Apply, Revert, Manual mode. Screenshot every state; compare with the approved mockups; fix.
- [ ] **Step 5: Sampler** — set `sample_minutes` to 2 temporarily, wait for ≥ 6 samples, confirm the exposure chip and a re-optimisation; lock the screen once and confirm the sample is skipped (log).
- [ ] **Step 6: Vertical** — enable in the lab; confirm `zz-pixel-shift.toml`, window geometry unchanged (`hyprctl clients -j`), no visible flicker; disable; file removed.
- [ ] **Step 7: Pause tile and IPC** — tile toggles; `noctalia msg plugin mgeldi/pixel-shift:engine all pause|resume|rescan` work.
- [ ] **Step 8: Performance** — note optimiser CPU seconds per output and scan duration in `docs/verification.md`.
- [ ] **Step 9: Commit** — `git commit -am "fix: issues found in live verification"` (plus the notes file).

### Task 23: README, thumbnail, screenshots, version 1.0.0

**Files:**
- Create: `pixel-shift/README.md`, `pixel-shift/thumbnail.webp`, `docs/screenshots/*.png`, `README.md` (repo), `LICENSE` (repo, MIT)
- Modify: `pixel-shift/plugin.toml` (`version = "1.0.0"`)

- [ ] **Step 1: Plugin README** following `README_TEMPLATE.md`: title + explanation; `Plugin` table (ID `mgeldi/pixel-shift`; entries: bar widget `spacer`, panel `lab`, service `engine`, shortcut `toggle`); `Requirements` (`grim`; optional `loginctl` for skipping samples while locked); `Usage` (placing spacers, `noctalia msg panel-toggle mgeldi/pixel-shift:lab`, the tile in Settings → Control Center); `Settings` table for `panel_profile`, `sample_minutes`, `step_minutes`, `max_shift`; `IPC` (`noctalia msg plugin mgeldi/pixel-shift:engine all pause|resume|toggle|rescan|optimize|lab`); `Notes` (how the model works in short and what it cannot promise; files written; processes spawned; no network; the vertical override file; privacy: only the bar strip is captured, only averages stored).
- [ ] **Step 2: Screenshots** — lab in ghost and risk view; blank window and media titles with `ppm.blank`-style filling (a small Python/PIL step is fine for docs images); store under `docs/screenshots/`.
- [ ] **Step 3: Thumbnail** — open `https://assets.noctalia.dev/plugins/thumbnail-generator.html` with Playwright, upload the ghost-view screenshot, title "Pixel Shift", category tag matching `utility`, accent = the glow colour; export the 960×540 WebP (read the canvas via `browser_evaluate` if the download is not captured) → `pixel-shift/thumbnail.webp`.
- [ ] **Step 4: Repo README + LICENSE** — short project page linking the plugin README, spec and screenshots; MIT license with the author's name.
- [ ] **Step 5: Version** — `version = "1.0.0"`; commit `docs: README, thumbnail and screenshots; release 1.0.0`.

### Task 24: GitHub repository and CI

- [ ] **Step 1:** `gh repo create mgeldi/noctalia-pixel-shift --public --source ~/Projects/noctalia-pixel-shift --description "Pixel Shift: OLED burn-in protection for the Noctalia bar" --push`
- [ ] **Step 2:** `gh run watch` until the `tests` workflow is green; fix and push if not.
- [ ] **Step 3:** Tag `v1.0.0` and push the tag; `gh release create v1.0.0 --notes-file` with a short summary.

### Task 25: Community plugin submission

- [ ] **Step 1:** `gh repo fork noctalia-dev/community-plugins --clone ~/Projects/community-plugins-fork` (or reuse), branch `add-pixel-shift`.
- [ ] **Step 2:** Copy `pixel-shift/` into the fork root; do not touch `catalog.toml`.
- [ ] **Step 3:** Run `python3 .github/workflows/scripts/validate-plugins.py` and `python3 -m unittest discover -s .github/workflows/scripts -p 'test_*.py'` in the fork; fix every error in the source repo and copy again.
- [ ] **Step 4:** Commit `Add mgeldi/pixel-shift` and push.
- [ ] **Step 5:** Open the PR with the community template filled in: New plugin; what it does; external dependencies (`grim`: bar captures; `loginctl`: optional lock check; `noctalia msg config-reload` only when vertical shift is enabled); testing (Hyprland, Noctalia 5.1.0, plugin API 32, entries exercised); screenshots (blanked titles); every checklist and attestation item checked only if true; disclosure of every file written (`pluginDataDir`: `state.json`, `layout-*.json`, `scan-*.bin`, `exposure-*.bin`, `render/*.bmp`; `$XDG_RUNTIME_DIR/pixel-shift-*.ppm` temporary captures; optional `zz-pixel-shift.toml` in the config dir) and every process spawned; no network.
- [ ] **Step 6:** Watch the PR checks (`gh pr checks --watch`); fix anything the validator or template bot reports.
