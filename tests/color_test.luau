--!nonstrict
local t = require("./testlib")
local color = require("../pixel-shift/core/color")

local function near8(c, r, g, b)
	t.near(c[1], r, 3, "red"); t.near(c[2], g, 3, "green"); t.near(c[3], b, 3, "blue")
end

t.test("color: sRGB transfer", function()
	t.near(color.toLinear8(0), 0); t.near(color.toLinear8(255), 1)
	t.near(color.toLinear8(128), 0.2158605, 1e-6)
	t.near(color.fromLinear(color.toLinear(0.5)), 0.5, 1e-9)
	t.eq(color.to8(1.2), 255); t.eq(color.to8(-1), 0)
end)

t.test("color: hex parsing and OKLCH", function()
	local r, g, b = color.hexToRgb("#ff8000")
	t.near(r, 1); t.near(g, 128 / 255); t.near(b, 0)
	t.eq(color.hexToRgb("nope"), nil)
	local L, C = color.hexToOklch("#ffffff")
	t.near(L, 1, 1e-3); t.near(C, 0, 1e-3)
end)

t.test("color: glow ramp matches the approved prototype", function()
	-- index 201 = t 200/255 (prototype hi[200])
	near8(color.glowRamp("#c1c5de")[201], 175, 185, 254)
	near8(color.glowRamp("#b58fff")[201], 213, 155, 254)
	near8(color.glowRamp("#8B2E2E")[201], 254, 131, 127)
end)

t.test("color: ramps rise in lightness and survive bad input", function()
	local ramp = color.glowRamp(nil)
	t.eq(#ramp, 256)
	local function lum(c) return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3] end
	t.ok(lum(ramp[1]) < lum(ramp[128]) and lum(ramp[128]) < lum(ramp[256]))
	local risk = color.riskRamp("#c1c5de")
	t.ok(lum(risk[1]) < lum(risk[256]))
end)

return {}
