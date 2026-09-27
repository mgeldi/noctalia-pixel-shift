--!nonstrict
local t = require("./testlib")
local ppm = require("../pixel-shift/core/ppm")
local bmp = require("../pixel-shift/core/bmp")

local function bytes(...)
	local parts = {}
	for _, v in ipairs({ ... }) do
		table.insert(parts, string.char(v))
	end
	return table.concat(parts)
end

t.test("ppm: parses P6 with comments", function()
	local img = assert(ppm.parse("P6\n# grim\n2 1\n255\n" .. bytes(255, 0, 0, 0, 255, 7)))
	t.eq(img.w, 2); t.eq(img.h, 1)
	local r, g, b = ppm.get(img, 1, 0)
	t.eq(r, 0); t.eq(g, 255); t.eq(b, 7)
end)

t.test("ppm: rejects bad input", function()
	t.eq(ppm.parse("P5\n1 1\n255\n\0"), nil)
	t.eq(ppm.parse("P6\n2 2\n255\n" .. bytes(1, 2, 3)), nil)
	t.eq(ppm.parse("P6\n1 1\n65535\n" .. bytes(0, 0, 0, 0, 0, 0)), nil)
	t.eq(ppm.parse(nil), nil)
end)

t.test("ppm: transpose swaps axes", function()
	local img = ppm.new(2, 1)
	ppm.set(img, 0, 0, 1, 2, 3); ppm.set(img, 1, 0, 4, 5, 6)
	local tr = ppm.transpose(img)
	t.eq(tr.w, 1); t.eq(tr.h, 2)
	local r = ppm.get(tr, 0, 1)
	t.eq(r, 4)
end)

t.test("bmp: header, padding, bottom-up BGR", function()
	local img = ppm.new(2, 2)
	ppm.set(img, 0, 0, 10, 20, 30) -- top-left
	ppm.set(img, 0, 1, 40, 50, 60) -- bottom-left
	local s = bmp.encode(img)
	t.eq(#s, 54 + 2 * 8)
	t.eq(string.sub(s, 1, 2), "BM")
	t.eq(string.unpack("<i4", s, 19), 2)
	t.eq(string.unpack("<i4", s, 23), 2)
	-- first stored row is the bottom row: B,G,R of (0,1)
	t.eq(string.byte(s, 55), 60); t.eq(string.byte(s, 56), 50); t.eq(string.byte(s, 57), 40)
	-- second stored row starts after 8 bytes: (0,0)
	t.eq(string.byte(s, 63), 30)
end)

return {}
