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
