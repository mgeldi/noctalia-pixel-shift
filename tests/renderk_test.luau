--!nonstrict
-- The lab's pixel loops run as unrolled kernels (see core/kernels.luau).
-- These tests pin them to straightforward reference versions on images of
-- awkward sizes, so the fast paths never change what the lab shows.
local t = require("./testlib")
local image = require("../pixel-shift/core/image")
local ppm = require("../pixel-shift/core/ppm")
local color = require("../pixel-shift/core/color")
local render = require("../pixel-shift/core/render")
local bmp = require("../pixel-shift/core/bmp")

local function lcg(seed)
	local s = seed
	return function()
		s = (s * 1103515245 + 12345) % 2147483648
		return s
	end
end

local function randF(w, h, seed, scale)
	local img, r = image.new(w, h), lcg(seed)
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			image.set(img, x, y, (r() % 1000) / 1000 * (scale or 1))
		end
	end
	return img
end

local function randRgb(w, h, seed)
	local img, r = ppm.new(w, h), lcg(seed)
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			ppm.set(img, x, y, r() % 256, r() % 256, r() % 256)
		end
	end
	return img
end

local function byte(v)
	v = math.floor(v + 0.5)
	return if v < 0 then 0 elseif v > 255 then 255 else v
end

local function smooth(e0, e1, x)
	local u = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return u * u * (3 - 2 * u)
end

local function sameRgb(a, b, what)
	t.eq(a.w, b.w, what .. " width")
	t.eq(a.h, b.h, what .. " height")
	for i = 0, a.w * a.h * 3 - 1 do
		if buffer.readu8(a.data, i) ~= buffer.readu8(b.data, i) then
			error(`{what}: byte {i} differs ({buffer.readu8(a.data, i)} vs {buffer.readu8(b.data, i)})`)
		end
	end
end

local SIZES = { { 1, 1 }, { 3, 2 }, { 5, 3 }, { 7, 4 }, { 13, 5 }, { 33, 6 } }

t.test("renderk: bmp rows match the reference encoder", function()
	for _, sz in ipairs(SIZES) do
		local img = randRgb(sz[1], sz[2], sz[1] * 7 + sz[2])
		local s = bmp.encode(img)
		local w, h = img.w, img.h
		local rowSize = (w * 3 + 3) // 4 * 4
		t.eq(#s, 54 + rowSize * h)
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local r, g, b = ppm.get(img, x, y)
				local o = 54 + (h - 1 - y) * rowSize + x * 3 + 1
				local B, G, R = string.byte(s, o, o + 2)
				if R ~= r or G ~= g or B ~= b then
					error(`bmp {w}x{h}: pixel {x},{y} differs`)
				end
			end
		end
	end
end)

t.test("renderk: scaleDown matches the area-average reference", function()
	for _, case in ipairs({ { 13, 5, 4 }, { 33, 6, 10 }, { 40, 9, 17 }, { 7, 4, 7 } }) do
		local img = randRgb(case[1], case[2], case[1] + case[3])
		local newW = case[3]
		local f = img.w / newW
		local newH = math.max(1, math.floor(img.h / f + 0.5))
		local ref = ppm.new(newW, newH)
		for oy = 0, newH - 1 do
			local sy0 = math.floor(oy * f)
			local sy1 = math.max(sy0 + 1, math.min(math.floor((oy + 1) * f), img.h))
			for ox = 0, newW - 1 do
				local sx0 = math.floor(ox * f)
				local sx1 = math.max(sx0 + 1, math.min(math.floor((ox + 1) * f), img.w))
				local r, g, b, n = 0, 0, 0, 0
				for y = sy0, sy1 - 1 do
					for x = sx0, sx1 - 1 do
						local pr, pg, pb = ppm.get(img, x, y)
						r, g, b, n = r + pr, g + pg, b + pb, n + 1
					end
				end
				ppm.set(ref, ox, oy, byte(r / n), byte(g / n), byte(b / n))
			end
		end
		sameRgb(render.scaleDown(img, newW), ref, `scaleDown {case[1]}->{newW}`)
	end
end)

t.test("renderk: ghost view matches the reference", function()
	local ramp = color.glowRamp("#8e8cd8")
	for _, sz in ipairs(SIZES) do
		local E, R = randF(sz[1], sz[2], 3 + sz[1], 2), randF(sz[1], sz[2], 11 + sz[2], 1.5)
		local eRef, rTop = 1.3, 0.9
		-- reference: grey from exposure, then the glow composite
		local base = image.new(E.w, E.h)
		for y = 0, E.h - 1 do
			for x = 0, E.w - 1 do
				local e = math.clamp(image.get(E, x, y) / eRef, 0, 1)
				image.set(base, x, y, (0.60 - 0.40 * e ^ 0.8) * 0.72)
			end
		end
		local tImg = image.new(R.w, R.h)
		for y = 0, R.h - 1 do
			for x = 0, R.w - 1 do
				image.set(tImg, x, y, math.clamp(image.get(R, x, y) / rTop, 0, 1))
			end
		end
		local bloom = image.gauss3(tImg, 1)
		local ref = ppm.new(R.w, R.h)
		for y = 0, R.h - 1 do
			for x = 0, R.w - 1 do
				local tt = math.min(image.get(tImg, x, y) + 0.35 * image.get(bloom, x, y), 1)
				local a = smooth(0.16, 0.55, tt)
				local c = ramp[math.floor(tt * 255) + 1]
				local g = image.get(base, x, y) * 255
				ppm.set(ref, x, y, byte(g * (1 - a) + c[1] * a), byte(g * (1 - a) + c[2] * a), byte(g * (1 - a) + c[3] * a))
			end
		end
		sameRgb(render.ghostView(E, R, eRef, rTop, ramp), ref, `ghost {sz[1]}x{sz[2]}`)
	end
end)

t.test("renderk: risk view and linear-to-sRGB match the reference", function()
	local ramp = color.riskRamp("#8e8cd8")
	for _, sz in ipairs(SIZES) do
		local lum, R = randF(sz[1], sz[2], 5 + sz[1]), randF(sz[1], sz[2], 17 + sz[2], 1.4)
		local rTop = 0.8
		local ref = ppm.new(R.w, R.h)
		for y = 0, R.h - 1 do
			for x = 0, R.w - 1 do
				local tr = math.clamp(image.get(R, x, y) / rTop, 0, 1) ^ 0.7
				local a = math.clamp(1.4 * tr, 0, 1)
				local g = color.fromLinear(image.get(lum, x, y)) * 0.2 * 255
				local c = ramp[math.floor(tr * 255) + 1]
				ppm.set(ref, x, y, byte(g * (1 - a) + c[1] * a), byte(g * (1 - a) + c[2] * a), byte(g * (1 - a) + c[3] * a))
			end
		end
		sameRgb(render.riskView(lum, R, rTop, ramp), ref, `risk {sz[1]}x{sz[2]}`)
		local lin = { w = lum.w, h = lum.h, r = lum, g = R, b = randF(sz[1], sz[2], 23 + sz[1], 1.2) }
		local refL = ppm.new(lum.w, lum.h)
		for y = 0, lum.h - 1 do
			for x = 0, lum.w - 1 do
				ppm.set(refL, x, y, color.to8(color.fromLinear(image.get(lin.r, x, y))),
					color.to8(color.fromLinear(image.get(lin.g, x, y))), color.to8(color.fromLinear(image.get(lin.b, x, y))))
			end
		end
		sameRgb(render.fromLinear(lin), refL, `fromLinear {sz[1]}x{sz[2]}`)
	end
end)

t.test("renderk: shiftColumns matches the clamped per-pixel reference", function()
	local img = randF(23, 3, 99)
	for _, case in ipairs({ { 0, 23, 5 }, { 0, 23, -5 }, { 4, 17, 3 }, { 4, 17, -9 }, { 10, 12, 30 }, { 0, 23, -40 }, { 3, 9, 0 } }) do
		local x0, x1, dx = case[1], case[2], case[3]
		local out = image.shiftColumns(img, x0, x1, dx)
		for y = 0, img.h - 1 do
			for x = 0, img.w - 1 do
				local want = image.get(img, x, y)
				if x >= x0 and x < x1 then
					want = image.get(img, math.clamp(x + dx, 0, img.w - 1), y)
				end
				if image.get(out, x, y) ~= want then
					error(`shiftColumns {x0},{x1},{dx}: {x},{y} differs`)
				end
			end
		end
	end
end)

t.test("renderk: luma straight from 8-bit captures is bit-identical", function()
	local wear = require("../pixel-shift/core/wear")
	for _, sz in ipairs(SIZES) do
		local img = randRgb(sz[1], sz[2], 41 + sz[1])
		local a = image.luma(wear.linearFromRgb8(img))
		local b = wear.lumaFromRgb8(img)
		for i = 0, a.w * a.h - 1 do
			if buffer.readf32(a.data, i * 4) ~= buffer.readf32(b.data, i * 4) then
				error(`luma {sz[1]}x{sz[2]}: pixel {i} differs`)
			end
		end
	end
end)

t.test("renderk: percentile matches the two-pass reference", function()
	for _, sz in ipairs({ { 7, 5 }, { 33, 6 }, { 64, 9 } }) do
		local img = randF(sz[1], sz[2], 7 * sz[1], 3)
		for _, q in ipairs({ 0.5, 0.9, 0.998 }) do
			local y0, y1 = 1, sz[2] - 1
			local lo, hi = math.huge, -math.huge
			for y = y0, y1 - 1 do for x = 0, img.w - 1 do
				local v = image.get(img, x, y)
				lo, hi = math.min(lo, v), math.max(hi, v)
			end end
			local bins, counts, n = 4096, table.create(4096, 0), 0
			local scale = bins / (hi - lo)
			for y = y0, y1 - 1 do for x = 0, img.w - 1 do
				local i = math.min(math.floor((image.get(img, x, y) - lo) * scale), bins - 1)
				counts[i + 1] += 1
				n += 1
			end end
			local want, acc = hi, 0
			for i = 1, bins do
				acc += counts[i]
				if acc >= q * n then
					want = lo + (i - 0.5) / scale
					break
				end
			end
			t.eq(image.percentile(img, q, y0, y1), want)
		end
	end
end)

t.test("renderk: a ghost view of a crop with a 3 px margin is exact inside", function()
	local ramp = color.glowRamp("#8e8cd8")
	local E, R = randF(40, 6, 5, 2), randF(40, 6, 9, 1.5)
	local full = render.ghostView(E, R, 1.3, 0.9, ramp)
	local x0, x1 = 12, 25
	local part = render.ghostView(image.crop(E, x0 - 3, x1 + 3), image.crop(R, x0 - 3, x1 + 3), 1.3, 0.9, ramp)
	for y = 0, 5 do
		for x = x0, x1 - 1 do
			local r1, g1, b1 = ppm.get(full, x, y)
			local r2, g2, b2 = ppm.get(part, x - x0 + 3, y)
			if r1 ~= r2 or g1 ~= g2 or b1 ~= b2 then
				error(`crop ghost differs at {x},{y}`)
			end
		end
	end
end)

t.test("renderk: the wear map kernel matches wear.pixel for every profile", function()
	local wear = require("../pixel-shift/core/wear")
	for _, sz in ipairs(SIZES) do
		-- values slightly outside 0..1 exercise the clamps
		local function plane(seed)
			local img, r = image.new(sz[1], sz[2]), lcg(seed)
			for y = 0, sz[2] - 1 do
				for x = 0, sz[1] - 1 do
					image.set(img, x, y, (r() % 1200) / 1000 - 0.1)
				end
			end
			return img
		end
		local lin = { w = sz[1], h = sz[2], r = plane(3 + sz[1]), g = plane(5 + sz[2]), b = plane(7 + sz[1]) }
		for _, name in ipairs(wear.ORDER) do
			local p = wear.profile(name)
			local out = wear.map(p, lin)
			for y = 0, sz[2] - 1 do
				for x = 0, sz[1] - 1 do
					local want = wear.pixel(p, image.get(lin.r, x, y), image.get(lin.g, x, y), image.get(lin.b, x, y))
					local b4 = buffer.create(4)
					buffer.writef32(b4, 0, want)
					if image.get(out, x, y) ~= buffer.readf32(b4, 0) then
						error(`wear.map {name} {sz[1]}x{sz[2]}: {x},{y} differs`)
					end
				end
			end
		end
	end
end)

return {}
