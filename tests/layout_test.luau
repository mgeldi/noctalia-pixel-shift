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
