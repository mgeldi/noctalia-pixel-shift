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
