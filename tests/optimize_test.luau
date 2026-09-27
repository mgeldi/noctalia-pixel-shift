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
