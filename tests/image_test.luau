--!nonstrict
local t = require("./testlib")
local image = require("../pixel-shift/core/image")

local function row(values)
	local img = image.new(#values, 1)
	for i, v in ipairs(values) do
		image.set(img, i - 1, 0, v)
	end
	return img
end

local function values(img, y)
	local out = {}
	for x = 0, img.w - 1 do
		out[x + 1] = image.get(img, x, y or 0)
	end
	return out
end

t.test("image: set/get round trip", function()
	local img = image.new(3, 2)
	image.set(img, 2, 1, 0.25)
	t.near(image.get(img, 2, 1), 0.25)
	t.near(image.get(img, 0, 0), 0)
end)

t.test("image: crop zero and clamp modes", function()
	local img = row({ 1, 2, 3 })
	local z = values(image.crop(img, -1, 4))
	t.near(z[1], 0); t.near(z[2], 1); t.near(z[4], 3); t.near(z[5], 0)
	local c = values(image.crop(img, -2, 5, "clamp"))
	t.near(c[1], 1); t.near(c[2], 1); t.near(c[3], 1); t.near(c[6], 3); t.near(c[7], 3)
end)

t.test("image: maskColumns keeps only the range", function()
	local v = values(image.maskColumns(row({ 1, 2, 3, 4 }), 1, 3))
	t.near(v[1], 0); t.near(v[2], 2); t.near(v[3], 3); t.near(v[4], 0)
end)

t.test("image: dirBoxH spreads right and left", function()
	local src = row({ 0, 0, 0, 0, 0, 3, 0, 0, 0, 0 })
	local r = values(image.dirBoxH(src, 2, 1))
	t.near(r[6], 1); t.near(r[7], 1); t.near(r[8], 1); t.near(r[9], 0); t.near(r[5], 0)
	local l = values(image.dirBoxH(src, 2, -1))
	t.near(l[4], 1); t.near(l[5], 1); t.near(l[6], 1); t.near(l[3], 0); t.near(l[7], 0)
	local same = values(image.dirBoxH(src, 0, 1))
	t.near(same[6], 3)
end)

t.test("image: dirBoxV spreads down", function()
	local img = image.new(1, 5)
	image.set(img, 0, 1, 2)
	local v = image.dirBoxV(img, 1, 1)
	t.near(image.get(v, 0, 1), 1); t.near(image.get(v, 0, 2), 1); t.near(image.get(v, 0, 3), 0)
end)

t.test("image: gauss3 keeps constants and mass", function()
	local c = image.new(20, 20)
	for y = 0, 19 do for x = 0, 19 do image.set(c, x, y, 0.7) end end
	local g = image.gauss3(c, 3)
	t.near(image.get(g, 0, 0), 0.7, 1e-5); t.near(image.get(g, 10, 10), 0.7, 1e-5)
	local imp = image.new(41, 41)
	image.set(imp, 20, 20, 1)
	local gi = image.gauss3(imp, 2)
	local sum = 0
	for y = 0, 40 do for x = 0, 40 do sum += image.get(gi, x, y) end end
	t.near(sum, 1, 1e-4)
	t.near(image.get(gi, 20, 20), (19 / 125) ^ 2, 1e-5)
end)

t.test("image: shiftColumns and shiftRows read from the offset", function()
	local s = values(image.shiftColumns(row({ 1, 2, 3, 4, 5 }), 1, 4, 1))
	t.near(s[1], 1); t.near(s[2], 3); t.near(s[3], 4); t.near(s[4], 5); t.near(s[5], 5)
	local img = image.new(1, 3)
	image.set(img, 0, 0, 1); image.set(img, 0, 1, 2); image.set(img, 0, 2, 3)
	local r = image.shiftRows(img, 1)
	t.near(image.get(r, 0, 0), 2); t.near(image.get(r, 0, 1), 3); t.near(image.get(r, 0, 2), 3)
end)

t.test("image: add, square, percentile, luma", function()
	local a = row({ 1, 2 })
	image.add(a, row({ 1, 1 }), 2)
	t.near(image.get(a, 1, 0), 4)
	t.near(image.get(image.square(a), 1, 0), 16)
	local p = image.new(100, 1)
	for x = 0, 99 do image.set(p, x, 0, x) end
	t.near(image.percentile(p, 0.5), 49, 0.2) -- nearest rank: 50 of 100 samples are <= 49
	local lin = image.rgbNew(1, 1)
	image.set(lin.r, 0, 0, 1)
	t.near(image.get(image.luma(lin), 0, 0), 0.2126, 1e-6)
end)

return {}
