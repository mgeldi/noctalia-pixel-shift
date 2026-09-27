--!nonstrict
-- The box filters are unrolled for speed (Noctalia's VM charges ~76 ns per
-- loop iteration). These tests pin them to naive reference versions on
-- random images of awkward sizes, including widths below the unroll factor
-- and radii larger than the image.
local t = require("./testlib")
local image = require("../pixel-shift/core/image")

local function rand(w, h, seed)
	local img = image.new(w, h)
	local s = seed
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			s = (s * 1103515245 + 12345) % 2147483648
			image.set(img, x, y, (s % 1000) / 1000)
		end
	end
	return img
end

local function clampi(v, a, b)
	return if v < a then a elseif v > b then b else v
end

local function naiveBox(src, r, horizontal)
	local out = image.new(src.w, src.h)
	for y = 0, src.h - 1 do
		for x = 0, src.w - 1 do
			local sum = 0
			for k = -r, r do
				if horizontal then
					sum += image.get(src, clampi(x + k, 0, src.w - 1), y)
				else
					sum += image.get(src, x, clampi(y + k, 0, src.h - 1))
				end
			end
			image.set(out, x, y, sum / (2 * r + 1))
		end
	end
	return out
end

local function naiveDir(src, range, dir, horizontal)
	local out = image.new(src.w, src.h)
	for y = 0, src.h - 1 do
		for x = 0, src.w - 1 do
			local sum = 0
			for o = 0, range do
				local sx, sy = x, y
				if horizontal then
					sx = x - dir * o
				else
					sy = y - dir * o
				end
				if sx >= 0 and sx < src.w and sy >= 0 and sy < src.h then
					sum += image.get(src, sx, sy)
				end
			end
			image.set(out, x, y, sum / (range + 1))
		end
	end
	return out
end

local function same(a, b, label)
	for y = 0, a.h - 1 do
		for x = 0, a.w - 1 do
			local d = math.abs(image.get(a, x, y) - image.get(b, x, y))
			if d > 1e-4 then
				error(`{label}: differs at {x},{y}: {image.get(a, x, y)} vs {image.get(b, x, y)}`, 2)
			end
		end
	end
end

local SIZES = { { 1, 1 }, { 3, 2 }, { 7, 5 }, { 8, 3 }, { 9, 4 }, { 17, 6 }, { 40, 11 }, { 131, 9 } }

t.test("filters: hbox and vbox match the naive box", function()
	for i, sz in ipairs(SIZES) do
		local src = rand(sz[1], sz[2], i)
		for _, r in ipairs({ 1, 2, 10 }) do
			local out = image.new(sz[1], sz[2])
			image.hbox(src, out, r)
			same(out, naiveBox(src, r, true), `hbox {sz[1]}x{sz[2]} r{r}`)
			image.vbox(src, out, r)
			same(out, naiveBox(src, r, false), `vbox {sz[1]}x{sz[2]} r{r}`)
		end
	end
end)

t.test("filters: dirBoxH and dirBoxV match the naive directional box", function()
	for i, sz in ipairs(SIZES) do
		local src = rand(sz[1], sz[2], 100 + i)
		for _, range in ipairs({ 1, 3, 9, 20 }) do
			for _, dir in ipairs({ 1, -1 }) do
				same(image.dirBoxH(src, range, dir), naiveDir(src, range, dir, true), `dirBoxH {sz[1]}x{sz[2]} {range} {dir}`)
				same(image.dirBoxV(src, range, dir), naiveDir(src, range, dir, false), `dirBoxV {sz[1]}x{sz[2]} {range} {dir}`)
			end
		end
	end
end)

t.test("filters: flat operations on sizes that are not multiples of 8", function()
	local a, b = rand(13, 3, 7), rand(13, 3, 8)
	local sum = image.copy(a)
	image.add(sum, b, 2)
	local sq = image.square(a)
	for y = 0, 2 do
		for x = 0, 12 do
			t.near(image.get(sum, x, y), image.get(a, x, y) + 2 * image.get(b, x, y), 1e-5)
			t.near(image.get(sq, x, y), image.get(a, x, y) ^ 2, 1e-5)
		end
	end
end)

return {}
