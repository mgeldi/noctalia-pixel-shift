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
	local e0 = simulate.evaluate(layers, layout, { ranges = { a = 0 }, vertical = 0 }, RREF)
	local e6 = simulate.evaluate(layers, layout, { ranges = { a = 6 }, vertical = 0 }, RREF)
	t.ok(e6.score < e0.score * 0.9, `expected a drop, got {e0.score} -> {e6.score}`)
	-- the peak (the stroke itself) falls far more than the p99 of a mostly empty image
	t.ok(image.percentile(e6.R, 1) < 0.5 * image.percentile(e0.R, 1), "peak risk should more than halve")
end)

t.test("simulate: active ranges shrink group windows without changing the result", function()
	local layers, layout = fixture()
	layout.groups[1].own0, layout.groups[1].own1 = 0, W -- group owns everything
	local active = simulate.activeRanges(layers, layout, 8)
	-- content in columns 100..101, reach 8, plus the coarse-blur context
	t.eq(active[1][1], 100 - 8 - simulate.CONTEXT)
	t.eq(active[1][2], 102 + 8 + simulate.CONTEXT)
	local ranges = { a = 5 }
	local full = simulate.evaluate(layers, layout, { ranges = ranges, vertical = 0 }, RREF)
	local merged = simulate.staticHist(layers, layout, RREF, active)
	risk.merge(merged, simulate.groupHist(layers, layout, 1, ranges, 0, RREF, active))
	t.eq(merged.n, full.hist.n)
	t.near(risk.percentile(merged, 0.99), risk.percentile(full.hist, 0.99), 0.02 * RREF)
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

t.test("simulate: prepared group histograms match groupHist", function()
	-- a richer fixture: two groups, a centre pair, text-like strokes and a wide block
	local wbg, dw = image.new(W, H), image.new(W, H)
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			image.set(wbg, x, y, 0.05 + 0.02 * ((x * 7 + y * 3) % 5))
		end
	end
	for y = 4, 15 do
		for _, x in ipairs({ 30, 31, 36, 42, 43, 50 }) do
			image.set(dw, x, y, 0.9)
		end
		for x = 120, 150 do
			image.set(dw, x, y, 0.6)
		end
	end
	local layers = { wbg = wbg, dw = dw }
	local layout = {
		w = W, h = H, scale = 1, vDir = 1,
		barRows = { 0, 18 }, scoreRows = { 0, 20 },
		groups = {
			{ x0 = 10, x1 = 80, own0 = 0, own1 = 90, factors = { a = 1 } },
			{ x0 = 100, x1 = 170, own0 = 90, own1 = 200, factors = { l = 0.5, r = -0.5 } },
		},
		slots = { a = { moves = true }, l = { moves = true }, r = { moves = true } },
	}
	local active = simulate.activeRanges(layers, layout, 18)
	local worst = 0
	for gi = 1, 2 do
		local P = simulate.prepareGroup(layers, layout, gi, active)
		for _, c in ipairs({ { a = 0, l = 0, r = 0, V = 0 }, { a = 7, l = 4, r = 9, V = 0 }, { a = 16, l = 12, r = 2, V = 1 }, { a = 3, l = 16, r = 16, V = 2 } }) do
			local ranges = { a = c.a, l = c.l, r = c.r }
			local ha = simulate.groupHist(layers, layout, gi, ranges, c.V, RREF, active)
			local hb = simulate.groupHistPrepared(P, layout, gi, ranges, c.V, RREF)
			worst = math.max(worst, math.abs(risk.percentile(ha, 0.99) - risk.percentile(hb, 0.99)) / RREF * 100)
		end
	end
	t.ok(worst < 0.05, `p99 differs by {worst} score points`)
end)

return {}
