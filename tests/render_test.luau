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
	t.near(image.get(g, 0, 0), 0.6 * 0.533, 1e-6) -- neutral 0.32
	t.near(image.get(g, 1, 0), 0.2 * 0.533, 1e-6)
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

t.test("render: scaleDown, halves, zoom, legend", function()
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
	local lg = render.legend(color.glowRamp("#c1c5de"), 64, 4)
	t.eq(lg.w, 64); t.eq(lg.h, 4)
end)

t.test("render: zoom matches the pixel-by-pixel reference", function()
	local img = ppm.new(9, 5)
	for y = 0, 4 do
		for x = 0, 8 do
			ppm.set(img, x, y, (x * 37 + y * 11) % 256, (x * 5 + y * 71) % 256, (x * y * 13) % 256)
		end
	end
	for _, z in ipairs({ 1, 2, 3 }) do
		local out = render.zoom(img, 2, 7, 1, 4, z)
		t.eq(out.w, 5 * z)
		t.eq(out.h, 3 * z)
		for y = 0, out.h - 1 do
			for x = 0, out.w - 1 do
				local r1, g1, b1 = ppm.get(out, x, y)
				local r2, g2, b2 = ppm.get(img, 2 + x // z, 1 + y // z)
				if r1 ~= r2 or g1 ~= g2 or b1 ~= b2 then
					error(`zoom {z} differs at {x},{y}`)
				end
			end
		end
	end
end)

t.test("render: the inspected region is framed on both overview halves", function()
	local left, right = ppm.new(4, 3), ppm.new(4, 3)
	render.frameHalves(left, right, 2, 6, 8, { 9, 8, 7 })
	t.eq((ppm.get(left, 2, 0)), 9, "top edge on the left half")
	t.eq((ppm.get(left, 3, 2)), 9, "bottom edge on the left half")
	t.eq((ppm.get(left, 2, 1)), 9, "left edge where the region starts")
	t.eq((ppm.get(left, 3, 1)), 0, "no edge at the cut between the halves")
	t.eq((ppm.get(left, 1, 0)), 0)
	t.eq((ppm.get(right, 0, 0)), 9)
	t.eq((ppm.get(right, 1, 1)), 9, "right edge where the region ends")
	t.eq((ppm.get(right, 0, 1)), 0)
	t.eq((ppm.get(right, 2, 0)), 0)
	local c = render.copy(left)
	t.eq((ppm.get(c, 2, 0)), 9)
	ppm.set(c, 2, 0, 1, 1, 1)
	t.eq((ppm.get(left, 2, 0)), 9, "copy is independent")
end)

return {}
