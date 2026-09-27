--!nonstrict
-- Pixel Shift engine (service). Owns all state: the spacer registry, one
-- record per output (scan, exposure, optimiser result), the player that turns
-- the active strategy into spacer widths, the vertical override, and the lab.

local util = require("./core/util.luau")
local budget = require("./core/budget.luau")
local image = require("./core/image.luau")
local wear = require("./core/wear.luau")
local risk = require("./core/risk.luau")
local layoutMod = require("./core/layout.luau")
local scanstore = require("./core/scanstore.luau")
local exposure = require("./core/exposure.luau")
local optimize = require("./core/optimize.luau")
local schedule = require("./core/schedule.luau")
local tasks = require("./runtime/tasks.luau")
local capture = require("./runtime/capture.luau")
local store = require("./runtime/store.luau")
local vertical = require("./runtime/vertical.luau")
local labmodel = require("./runtime/labmodel.luau")
local theme = require("./runtime/theme.luau")

-- Fast copy of core/kernels.luau (Noctalia gives only the entry script fast
-- builtin calls; tools/check-kernels.py keeps this identical to the module).
-- BEGIN KERNELS
local K = {}
do
	local rf, wf = buffer.readf32, buffer.writef32
	local rd, wd = buffer.readf64, buffer.writef64

	-- d += sd * k over n bytes
	function K.add(d: buffer, sd: buffer, n: number, k: number)
		local o = 0
		while o + 28 < n do
			if o % 65536 == 0 then
				budget.check()
			end
			wf(d, o, rf(d, o) + rf(sd, o) * k)
			wf(d, o + 4, rf(d, o + 4) + rf(sd, o + 4) * k)
			wf(d, o + 8, rf(d, o + 8) + rf(sd, o + 8) * k)
			wf(d, o + 12, rf(d, o + 12) + rf(sd, o + 12) * k)
			wf(d, o + 16, rf(d, o + 16) + rf(sd, o + 16) * k)
			wf(d, o + 20, rf(d, o + 20) + rf(sd, o + 20) * k)
			wf(d, o + 24, rf(d, o + 24) + rf(sd, o + 24) * k)
			wf(d, o + 28, rf(d, o + 28) + rf(sd, o + 28) * k)
			o += 32
		end
		while o < n do
			wf(d, o, rf(d, o) + rf(sd, o) * k)
			o += 4
		end
	end

	-- acc[x] += src[row][x] * sign
	local function accAdd(acc, src, row: number, w: number, sign: number)
		local x = 0
		while x + 7 < w do
			local a, o = x * 8, row + x * 4
			wd(acc, a, rd(acc, a) + rf(src, o) * sign)
			wd(acc, a + 8, rd(acc, a + 8) + rf(src, o + 4) * sign)
			wd(acc, a + 16, rd(acc, a + 16) + rf(src, o + 8) * sign)
			wd(acc, a + 24, rd(acc, a + 24) + rf(src, o + 12) * sign)
			wd(acc, a + 32, rd(acc, a + 32) + rf(src, o + 16) * sign)
			wd(acc, a + 40, rd(acc, a + 40) + rf(src, o + 20) * sign)
			wd(acc, a + 48, rd(acc, a + 48) + rf(src, o + 24) * sign)
			wd(acc, a + 56, rd(acc, a + 56) + rf(src, o + 28) * sign)
			x += 8
		end
		while x < w do
			wd(acc, x * 8, rd(acc, x * 8) + rf(src, row + x * 4) * sign)
			x += 1
		end
	end

	-- acc[x] += src[inRow][x] - src[outRow][x]
	local function accSlide(acc, src, inRow: number, outRow: number, w: number)
		local x = 0
		while x + 7 < w do
			local a, i, o = x * 8, inRow + x * 4, outRow + x * 4
			wd(acc, a, rd(acc, a) + rf(src, i) - rf(src, o))
			wd(acc, a + 8, rd(acc, a + 8) + rf(src, i + 4) - rf(src, o + 4))
			wd(acc, a + 16, rd(acc, a + 16) + rf(src, i + 8) - rf(src, o + 8))
			wd(acc, a + 24, rd(acc, a + 24) + rf(src, i + 12) - rf(src, o + 12))
			wd(acc, a + 32, rd(acc, a + 32) + rf(src, i + 16) - rf(src, o + 16))
			wd(acc, a + 40, rd(acc, a + 40) + rf(src, i + 20) - rf(src, o + 20))
			wd(acc, a + 48, rd(acc, a + 48) + rf(src, i + 24) - rf(src, o + 24))
			wd(acc, a + 56, rd(acc, a + 56) + rf(src, i + 28) - rf(src, o + 28))
			x += 8
		end
		while x < w do
			wd(acc, x * 8, rd(acc, x * 8) + rf(src, inRow + x * 4) - rf(src, outRow + x * 4))
			x += 1
		end
	end

	-- dst[row][x] = acc[x] * inv
	local function accWrite(acc, dst, row: number, w: number, inv: number)
		local x = 0
		while x + 7 < w do
			local a, o = x * 8, row + x * 4
			wf(dst, o, rd(acc, a) * inv)
			wf(dst, o + 4, rd(acc, a + 8) * inv)
			wf(dst, o + 8, rd(acc, a + 16) * inv)
			wf(dst, o + 12, rd(acc, a + 24) * inv)
			wf(dst, o + 16, rd(acc, a + 32) * inv)
			wf(dst, o + 20, rd(acc, a + 40) * inv)
			wf(dst, o + 24, rd(acc, a + 48) * inv)
			wf(dst, o + 28, rd(acc, a + 56) * inv)
			x += 8
		end
		while x < w do
			wf(dst, row + x * 4, rd(acc, x * 8) * inv)
			x += 1
		end
	end

	-- Centred box of radius r with replicated edges.
	function K.hbox(s: buffer, d: buffer, w: number, h: number, r: number)
		local inv = 1 / (2 * r + 1)
		local ahead, back = (r + 1) * 4, r * 4
		local m1 = w - r - 2 -- last column whose window needs no clamping
		for y = 0, h - 1 do
			budget.check()
			local row = y * w * 4
			local acc = 0
			for k = -r, r do
				local x = if k < 0 then 0 elseif k >= w then w - 1 else k
				acc += rf(s, row + x * 4)
			end
			local x = 0
			while x < w and x <= r do
				wf(d, row + x * 4, acc * inv)
				local xo = x - r
				if xo < 0 then
					xo = 0
				end
				local xi = x + r + 1
				if xi >= w then
					xi = w - 1
				end
				acc += rf(s, row + xi * 4) - rf(s, row + xo * 4)
				x += 1
			end
			local o = row + x * 4
			while x + 7 <= m1 do
				wf(d, o, acc * inv)
				acc += rf(s, o + ahead) - rf(s, o - back)
				wf(d, o + 4, acc * inv)
				acc += rf(s, o + 4 + ahead) - rf(s, o + 4 - back)
				wf(d, o + 8, acc * inv)
				acc += rf(s, o + 8 + ahead) - rf(s, o + 8 - back)
				wf(d, o + 12, acc * inv)
				acc += rf(s, o + 12 + ahead) - rf(s, o + 12 - back)
				wf(d, o + 16, acc * inv)
				acc += rf(s, o + 16 + ahead) - rf(s, o + 16 - back)
				wf(d, o + 20, acc * inv)
				acc += rf(s, o + 20 + ahead) - rf(s, o + 20 - back)
				wf(d, o + 24, acc * inv)
				acc += rf(s, o + 24 + ahead) - rf(s, o + 24 - back)
				wf(d, o + 28, acc * inv)
				acc += rf(s, o + 28 + ahead) - rf(s, o + 28 - back)
				o += 32
				x += 8
			end
			while x < w do
				wf(d, row + x * 4, acc * inv)
				local xo = x - r
				if xo < 0 then
					xo = 0
				end
				local xi = x + r + 1
				if xi >= w then
					xi = w - 1
				end
				acc += rf(s, row + xi * 4) - rf(s, row + xo * 4)
				x += 1
			end
		end
	end

	-- Vertical box, computed row by row with one accumulator per column.
	function K.vbox(s: buffer, d: buffer, w: number, h: number, r: number)
		local inv = 1 / (2 * r + 1)
		local stride = w * 4
		local acc = buffer.create(w * 8)
		for k = -r, r do
			local y = if k < 0 then 0 elseif k >= h then h - 1 else k
			accAdd(acc, s, y * stride, w, 1)
		end
		for y = 0, h - 1 do
			budget.check()
			accWrite(acc, d, y * stride, w, inv)
			local yo = y - r
			if yo < 0 then
				yo = 0
			end
			local yi = y + r + 1
			if yi >= h then
				yi = h - 1
			end
			if yi ~= yo then
				accSlide(acc, s, yi * stride, yo * stride, w)
			end
		end
	end

	-- Mean of src over offsets 0..range in direction dir: dir = +1 means content
	-- moved right, so out(x) averages src(x - o). Zero outside the image.
	-- (range >= 1; the caller handles range 0 as a copy)
	function K.dirBoxH(s: buffer, d: buffer, w: number, h: number, range: number, dir: number)
		local inv = 1 / (range + 1)
		local span = (range + 1) * 4
		for y = 0, h - 1 do
			budget.check()
			local row = y * w * 4
			local acc = 0
			if dir >= 0 then
				local x = 0
				while x < w and x <= range do
					acc += rf(s, row + x * 4)
					wf(d, row + x * 4, acc * inv)
					x += 1
				end
				local o = row + x * 4
				while x + 7 < w do
					acc += rf(s, o) - rf(s, o - span)
					wf(d, o, acc * inv)
					acc += rf(s, o + 4) - rf(s, o + 4 - span)
					wf(d, o + 4, acc * inv)
					acc += rf(s, o + 8) - rf(s, o + 8 - span)
					wf(d, o + 8, acc * inv)
					acc += rf(s, o + 12) - rf(s, o + 12 - span)
					wf(d, o + 12, acc * inv)
					acc += rf(s, o + 16) - rf(s, o + 16 - span)
					wf(d, o + 16, acc * inv)
					acc += rf(s, o + 20) - rf(s, o + 20 - span)
					wf(d, o + 20, acc * inv)
					acc += rf(s, o + 24) - rf(s, o + 24 - span)
					wf(d, o + 24, acc * inv)
					acc += rf(s, o + 28) - rf(s, o + 28 - span)
					wf(d, o + 28, acc * inv)
					o += 32
					x += 8
				end
				while x < w do
					acc += rf(s, row + x * 4) - rf(s, row + (x - range - 1) * 4)
					wf(d, row + x * 4, acc * inv)
					x += 1
				end
			else
				local x = w - 1
				while x >= 0 and x + range + 1 >= w do
					acc += rf(s, row + x * 4)
					wf(d, row + x * 4, acc * inv)
					x -= 1
				end
				local o = row + x * 4
				while x - 7 >= 0 do
					acc += rf(s, o) - rf(s, o + span)
					wf(d, o, acc * inv)
					acc += rf(s, o - 4) - rf(s, o - 4 + span)
					wf(d, o - 4, acc * inv)
					acc += rf(s, o - 8) - rf(s, o - 8 + span)
					wf(d, o - 8, acc * inv)
					acc += rf(s, o - 12) - rf(s, o - 12 + span)
					wf(d, o - 12, acc * inv)
					acc += rf(s, o - 16) - rf(s, o - 16 + span)
					wf(d, o - 16, acc * inv)
					acc += rf(s, o - 20) - rf(s, o - 20 + span)
					wf(d, o - 20, acc * inv)
					acc += rf(s, o - 24) - rf(s, o - 24 + span)
					wf(d, o - 24, acc * inv)
					acc += rf(s, o - 28) - rf(s, o - 28 + span)
					wf(d, o - 28, acc * inv)
					o -= 32
					x -= 8
				end
				while x >= 0 do
					acc += rf(s, row + x * 4) - rf(s, row + (x + range + 1) * 4)
					wf(d, row + x * 4, acc * inv)
					x -= 1
				end
			end
		end
	end

	-- Vertical counterpart of dirBoxH (dir = +1: content moved down), row by row
	-- with one accumulator per column.
	function K.dirBoxV(s: buffer, d: buffer, w: number, h: number, range: number, dir: number)
		local inv = 1 / (range + 1)
		local stride = w * 4
		local acc = buffer.create(w * 8)
		if dir >= 0 then
			for y = 0, h - 1 do
				budget.check()
				local yo = y - range - 1
				if yo >= 0 then
					accSlide(acc, s, y * stride, yo * stride, w)
				else
					accAdd(acc, s, y * stride, w, 1)
				end
				accWrite(acc, d, y * stride, w, inv)
			end
		else
			for y = h - 1, 0, -1 do
				budget.check()
				local yo = y + range + 1
				if yo < h then
					accSlide(acc, s, y * stride, yo * stride, w)
				else
					accAdd(acc, s, y * stride, w, 1)
				end
				accWrite(acc, d, y * stride, w, inv)
			end
		end
	end

	-- R = |E - a| + cw * |E - b| over n bytes (a, b: the two blurs of E)
	function K.riskCombine(e: buffer, a: buffer, b: buffer, r: buffer, n: number, cw: number)
		local o = 0
		while o + 12 < n do
			if o % 65536 == 0 then
				budget.check()
			end
			local v0, v1, v2, v3 = rf(e, o), rf(e, o + 4), rf(e, o + 8), rf(e, o + 12)
			wf(r, o, math.abs(v0 - rf(a, o)) + cw * math.abs(v0 - rf(b, o)))
			wf(r, o + 4, math.abs(v1 - rf(a, o + 4)) + cw * math.abs(v1 - rf(b, o + 4)))
			wf(r, o + 8, math.abs(v2 - rf(a, o + 8)) + cw * math.abs(v2 - rf(b, o + 8)))
			wf(r, o + 12, math.abs(v3 - rf(a, o + 12)) + cw * math.abs(v3 - rf(b, o + 12)))
			o += 16
		end
		while o < n do
			local v = rf(e, o)
			wf(r, o, math.abs(v - rf(a, o)) + cw * math.abs(v - rf(b, o)))
			o += 4
		end
	end

	-- d[i] += s[i] for i = 1..n (histogram merge; n is a multiple of 8)
	function K.mergeBins(d, s, n: number)
		for i = 1, n, 8 do
			d[i] += s[i]
			d[i + 1] += s[i + 1]
			d[i + 2] += s[i + 2]
			d[i + 3] += s[i + 3]
			d[i + 4] += s[i + 4]
			d[i + 5] += s[i + 5]
			d[i + 6] += s[i + 6]
			d[i + 7] += s[i + 7]
		end
	end

	-- bins[floor(v * scale)] += 1 for count floats starting at byte offset o
	function K.histogram(bins, data: buffer, o: number, count: number, scale: number, top: number)
		local stop = o + count * 4
		while o + 12 < stop do
			local i0 = math.min(math.max(math.floor(rf(data, o) * scale), 0), top)
			local i1 = math.min(math.max(math.floor(rf(data, o + 4) * scale), 0), top)
			local i2 = math.min(math.max(math.floor(rf(data, o + 8) * scale), 0), top)
			local i3 = math.min(math.max(math.floor(rf(data, o + 12) * scale), 0), top)
			bins[i0 + 1] += 1
			bins[i1 + 1] += 1
			bins[i2 + 1] += 1
			bins[i3 + 1] += 1
			o += 16
		end
		while o < stop do
			local i = math.min(math.max(math.floor(rf(data, o) * scale), 0), top)
			bins[i + 1] += 1
			o += 4
		end
	end
end
-- END KERNELS
image.install(K)
risk.install(K)

local PROBE = 8 -- logical px each spacer is widened by while measuring
local SETTLE_MS = 150 -- wait after the spacers acknowledged before capturing
local STALE = 120 -- s without a hello before a spacer is dropped
local MIN_SAMPLES = 6 -- exposure samples before they replace the scan
local OPT_SLICE_MS = 6
local SLICE_MS = 8 -- Noctalia stops a callback after ~25 ms of CPU
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
local dataDirty = true -- lab images/data need rebuilding (not just the status line)
local lastData = nil
local themeHex = nil
local optimizer = nil -- {name, opt, started, allowVertical}
local spacerChangedAt = os.time()
local fingerprintDue = true
local lastFingerprint, lastSlow, lastVertical = 0, 0, -1
local verticalCheckAt = nil
local errors = {}
local lastCmd = nil

-- Heavy core loops call budget.check(); inside a task or the optimiser this
-- yields once the slice is used up, so no callback comes near the host's
-- CPU budget. Outside a coroutine it does nothing.
local sliceStart = os.clock()
budget.hook = function()
	if (os.clock() - sliceStart) * 1000 >= SLICE_MS and coroutine.isyieldable() then
		coroutine.yield()
	end
end

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
	dataDirty = true

	dataDirty = true
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
	dataDirty = true
end

local function rebuildLayersAsync(O)
	O.layers = nil
	tasks.spawn("layers:" .. O.name, function()
		rebuildLayers(O)
	end)
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
	dataDirty = true
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
			dataDirty = true
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
		noctalia.log("pixel-shift: measuring " .. name)
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

		-- noctalia.outputs() reports the integer buffer scale (2 for 1.5), so the
		-- physical scale comes from the capture itself.
		local scale = baseA.w / (if geom.transpose then out.height else out.width)
		local barPx = math.floor(bar.thickness * scale + 0.5)
		local barRows, scoreRows = util.rowLayout(geom.flipped, baseA.h, barPx)
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
			scale = scale,
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
		O.info = { width = out.width, thickness = bar.thickness, scale = scale }
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
		noctalia.log(`pixel-shift: measured {name}: {#l.groups} groups, verify error {string.format("%.2f", verr)}`)
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
		dataDirty = true
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
		seconds = run.cpu or 0, -- time spent inside the optimiser slices
		allowVertical = run.allowVertical,
	}
	noctalia.log(`pixel-shift: optimized {run.name}: {#O.result.entries} strategies, {O.result.evals} evaluations, {string.format("%.1f", O.result.seconds)} s in {run.steps or 0} slices`)
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
			if O.fp ~= fp and not tasks.running("restore:" .. name) then
				O.fp = fp
				tasks.spawn("restore:" .. name, function()
					if not restore(O, fp) then
						O.fp = nil
						O.needsScan = true
						O.retryAt = 0
					elseif O.result == nil then
						O.needsOptimize = true
					end
				end)
			end
		end
	end
end

-- lab -----------------------------------------------------------------------------
local function renderLab()
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
	if not dataDirty and lastData then
		model.data = lastData
	elseif O and O.layout and O.layers then
		local meta = saved.outputs[ui.output] or {}
		local active = activeStrategy(ui.output)
		local ok, data = pcall(labmodel.build, O, ui, {
			primary = themeHex,
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
			lastData = data
			dataDirty = false
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
	dataDirty = true
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
		local target = (type(arg) == "string" and outputs[arg]) or O
		if target then
			target.needsOptimize = true
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
		if labOpen and not tasks.running("theme") then
			tasks.spawn("theme", function()
				local hex = theme.resolve(ui.output)
				if hex ~= themeHex then
					themeHex = hex
					dataDirty = true
				end
				labDirty = true
				dataDirty = true
			end)
		end
	elseif cmd == "openBarSettings" then
		noctalia.runAsync({ "noctalia", "msg", "settings-open", "bar" })
	end
	labDirty = true
	dataDirty = true

	dataDirty = true
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
	if event == "debug" then
		local ids = {}
		for id, info in pairs(spacers) do
			table.insert(ids, id .. "@" .. info.output)
		end
		local outs = {}
		for name, O in pairs(outputs) do
			table.insert(outs, `{name}: fp={tostring(O.fp)} layout={O.layout ~= nil} scan={O.needsScan} opt={O.needsOptimize} retry={O.retryAt}`)
		end
		local ws = {}
		for id, v in pairs(widths) do
			table.insert(ws, `{id}={v}`)
		end
		table.sort(ws)
		noctalia.log(`pixel-shift debug: spacers=[{table.concat(ids, ", ")}] outputs=[{table.concat(outs, "; ")}] status={status.kind} tasks={tasks.active()} optimizer={optimizer ~= nil} widths=[{table.concat(ws, ", ")}]`)
		return
	end
	if event == "pause" or event == "resume" or event == "toggle" or event == "rescan" or event == "optimize" then
		handle(event, payload)
	elseif event == "lab" then
		noctalia.togglePanel("mgeldi/pixel-shift:lab")
	end
end

function onConfigChanged()
	for _, O in pairs(outputs) do
		if O.layout then
			rebuildLayersAsync(O)
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
	sliceStart = os.clock()
	tasks.tick()
	if optimizer then
		local left = math.max(1, OPT_SLICE_MS - (os.clock() - sliceStart) * 1000)
		sliceStart = os.clock()
		local stepDone = optimizer.opt:step(left)
		optimizer.cpu = (optimizer.cpu or 0) + (os.clock() - sliceStart)
		optimizer.steps = (optimizer.steps or 0) + 1
		if stepDone then
			finishOptimize()
		elseif now ~= lastSlow then
			labDirty = true -- progress only: the lab reuses its images
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
						rebuildLayersAsync(O)
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
		labDirty = false
		tasks.spawn("lab", renderLab)
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
