--!nonstrict
-- End-to-end check of the analysis pipeline behind the lab: synthetic bar
-- captures -> layout -> layers -> optimiser -> labmodel.build.
local t = require("./testlib")

-- Rendered images are only counted: the writer mimics store.writeImage
-- (one current file per slot, the previous one removed).
local written, bySlot, counter = {}, {}, 0
local function writeImage(slot, bytes)
	counter += 1
	local path = `/fake/{slot}-{counter}.bmp`
	if bySlot[slot] then
		written[bySlot[slot]] = nil
	end
	bySlot[slot], written[path] = path, #bytes
	return path
end

local image = require("../pixel-shift/core/image")
local ppm = require("../pixel-shift/core/ppm")
local wear = require("../pixel-shift/core/wear")
local risk = require("../pixel-shift/core/risk")
local layout = require("../pixel-shift/core/layout")
local optimize = require("../pixel-shift/core/optimize")
local labmodel = require("../pixel-shift/runtime/labmodel")

local W, H, BAR = 400, 40, 32

-- A dark bar with a left group (strokes + a wide pill) shifted by dx.
local function capture(dx)
	local img = ppm.new(W, H)
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			if y < BAR then
				ppm.set(img, x, y, 20, 20, 24)
			else
				ppm.set(img, x, y, 60, 60, 60)
			end
		end
	end
	for _, x in ipairs({ 30, 31, 36, 37, 42, 43, 48, 49 }) do
		for y = 10, 21 do
			ppm.set(img, x + dx, y, 230, 230, 230)
		end
	end
	for x = 70, 109 do
		for y = 11, 20 do
			ppm.set(img, x + dx, y, 190, 195, 220)
		end
	end
	return img
end

local function luma(img)
	return image.luma(wear.linearFromRgb8(img))
end

t.test("labmodel: spacer labels follow the group each spacer moves most", function()
	local layout = {
		w = 3840,
		groups = {
			{ c0 = 1640, c1 = 2200, own0 = 1000, own1 = 2800, factors = { a = 0.75, b = -0.75 } },
			{ c0 = 2880, c1 = 3820, own0 = 2800, own1 = 3840, factors = { b = -0.75, c = -1.5 } },
		},
	}
	t.eq(labmodel.slotLabel(layout, "a"), "center_l")
	t.eq(labmodel.slotLabel(layout, "b"), "center_r")
	t.eq(labmodel.slotLabel(layout, "c"), "right", "same-sign neighbours are not a centre pair")
	t.eq(labmodel.slotLabel(layout, "zzz"), "unknown")
end)

t.test("labmodel: pipeline from captures to lab data", function()
	local base = capture(0)
	local lin = wear.linearFromRgb8(base)
	local l, diff = layout.build({
		base = luma(base),
		baseB = luma(capture(0)),
		probes = { ["DP-2#1"] = luma(capture(8)) },
		probePx = 8,
		scale = 1,
		barRows = { 0, BAR },
		scoreRows = { 0, BAR + 2 },
		vDir = 1,
	})
	t.eq(#l.groups, 1)
	local bg = layout.background(lin, l, diff)
	local p = wear.profile("generic")
	local O = {
		layout = l,
		layers = layout.layers(p, lin, bg),
		layersId = 1,
		base = lin,
		rref = risk.reference(p),
		info = { width = W, thickness = BAR },
		approximate = false,
	}
	local opt = optimize.new({ layers = O.layers, layout = l, rref = O.rref, maxShift = 8, maxV = 0, budgets = { 0, 4, 8 } })
	for _ = 1, 1000 do
		if opt:step(50) then
			break
		end
	end
	t.eq(opt.error, nil)
	local result = { entries = opt.entries, budgets = opt.budgets, evals = opt.evals, at = 0, seconds = 1, allowVertical = false }
	local pick = optimize.pick(opt.entries, optimize.lambdaFromSlider(0.43), false)
	local data = labmodel.build(O, { view = "ghost", mode = "strategy", hotspot = 1 }, {
		primary = "#c1c5de",
		profile = "generic",
		preview = { ranges = pick.ranges, vertical = 0 },
		active = { ranges = pick.ranges, vertical = 0 },
		previewing = false,
		result = result,
		allowVertical = false,
		lambdaT = 0.43,
		maxShift = 8,
		stepMinutes = 4,
		canRevert = false,
		writeImage = writeImage,
	})
	t.ok(data.score.strategy < data.score.none, `strategy {data.score.strategy} should beat {data.score.none}`)
	t.ok(data.overview.left and data.overview.right and data.legend, "images written")
	t.eq(data.overview.w, 860)
	t.eq(#data.overview.pins, #data.hotspots)
	t.ok(data.inspector.w <= 560 and data.inspector.w >= 540, "inspector about 560 px wide (zoom times region)")
	t.eq(#data.chips, 1)
	t.eq(data.chips[1].slot, "left")
	t.ok(data.curve ~= nil and data.curve.pick ~= nil, "curve with a pick")
	t.eq(#data.curve.h, 3)
	local count = 0
	for _ in pairs(written) do
		count += 1
	end
	t.eq(count, 5, "five current renders (older ones deleted)")
end)

return {}
