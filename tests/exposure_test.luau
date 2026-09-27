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

-- The reviewer's case: a dark bar with sparse 1-px text strokes, and covers
-- (lock screen, dark fullscreen app) of about the same darkness.
local W, H, BAR = 640, 42, 34
local SPARSE = { w = W, h = H, barRows = { 0, BAR }, scoreRows = { 0, BAR + 2 }, groups = {} }

local function lin(v: number): number -- sRGB 0..255 -> linear
	local s = v / 255
	return if s <= 0.04045 then s / 12.92 else ((s + 0.055) / 1.055) ^ 2.4
end

local function sparseBar(bg: number, title: number)
	local img = image.new(W, H)
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			image.set(img, x, y, lin(if y < BAR then bg else 40))
		end
	end
	local function strokes(x0, x1, every, phase)
		for x = x0, x1 - 1 do
			if (x + phase) % every == 0 then
				for y = 11, 22 do
					image.set(img, x, y, lin(220))
				end
			end
		end
	end
	strokes(8, 130, 6, 0) -- workspaces
	strokes(230, 420, 5, title) -- window title
	strokes(520, 632, 6, 0) -- tray and clock
	return img
end

local function cover(level: number)
	local img = image.new(W, H)
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			image.set(img, x, y, lin(level))
		end
	end
	for x = 300, 340 do -- a lock-screen clock
		if x % 3 == 0 then
			for y = 8, 30 do
				image.set(img, x, y, lin(235))
			end
		end
	end
	return img
end

t.test("exposure: the bar with a new window title still matches", function()
	t.eq(exposure.matchesBaseline(sparseBar(18, 0), sparseBar(18, 0), SPARSE), true)
	t.eq(exposure.matchesBaseline(sparseBar(18, 2), sparseBar(18, 0), SPARSE), true)
	t.eq(exposure.matchesBaseline(sparseBar(0, 3), sparseBar(0, 0), SPARSE), true)
end)

t.test("exposure: a dark cover does not pass as a dark bar", function()
	for _, level in ipairs({ 10, 25, 40 }) do
		t.eq(exposure.matchesBaseline(cover(level), sparseBar(18, 0), SPARSE), false, `cover at sRGB {level}`)
	end
end)

t.test("exposure: a black cover does not pass as a black bar", function()
	t.eq(exposure.matchesBaseline(cover(0), sparseBar(0, 0), SPARSE), false)
end)

t.test("exposure: blank detection is relative to the scanned bar", function()
	local img = ppm.new(1000, 1)
	for x = 0, 4 do ppm.set(img, x, 0, 200, 200, 200) end -- 0.5 % bright pixels
	t.eq(exposure.isBlank(img), true)
	t.eq(exposure.isBlank(img, 0.005), false, "a minimal black bar is not blank")
	t.near(exposure.brightFraction(img), 0.005, 1e-9)
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
