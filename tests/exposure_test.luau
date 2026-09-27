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
