--!nonstrict
local t = require("./testlib")
local image = require("../pixel-shift/core/image")
local scanstore = require("../pixel-shift/core/scanstore")

t.test("scanstore: round trip", function()
	local a, b = image.rgbNew(3, 2), image.rgbNew(3, 2)
	image.set(a.g, 2, 1, 0.5); image.set(b.b, 0, 0, 0.25)
	local base, bg = scanstore.decode(scanstore.encode(a, b))
	t.eq(base.w, 3); t.eq(base.h, 2)
	t.near(image.get(base.g, 2, 1), 0.5); t.near(image.get(bg.b, 0, 0), 0.25)
end)

t.test("scanstore: garbage and truncation decode to nil", function()
	t.eq(scanstore.decode("garbage"), nil)
	t.eq(scanstore.decode(nil), nil)
	local s = scanstore.encode(image.rgbNew(3, 2), image.rgbNew(3, 2))
	t.eq(scanstore.decode(string.sub(s, 1, #s - 4)), nil)
end)

return {}
