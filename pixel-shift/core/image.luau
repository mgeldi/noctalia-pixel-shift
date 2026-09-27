--!nonstrict
-- Single-channel f32 images (row-major) and the O(pixels) filters the wear
-- model needs. LinearRGB bundles three channels in linear light.

export type Image = { w: number, h: number, data: buffer }
export type LinearRGB = { w: number, h: number, r: Image, g: Image, b: Image }

local rf, wf = buffer.readf32, buffer.writef32

local M = {}

function M.new(w: number, h: number): Image
	return { w = w, h = h, data = buffer.create(w * h * 4) }
end

function M.get(img: Image, x: number, y: number): number
	return rf(img.data, (y * img.w + x) * 4)
end

function M.set(img: Image, x: number, y: number, v: number)
	wf(img.data, (y * img.w + x) * 4, v)
end

function M.copy(img: Image): Image
	local out = M.new(img.w, img.h)
	buffer.copy(out.data, 0, img.data)
	return out
end

-- Columns [x0, x1) as a new image. Outside columns read as 0 ("zero") or as
-- the nearest edge column ("clamp").
function M.crop(img: Image, x0: number, x1: number, mode: string?): Image
	local w = x1 - x0
	local out = M.new(w, img.h)
	local a, b = math.max(x0, 0), math.min(x1, img.w)
	for y = 0, img.h - 1 do
		if b > a then
			buffer.copy(out.data, (y * w + a - x0) * 4, img.data, (y * img.w + a) * 4, (b - a) * 4)
		end
		if mode == "clamp" then
			local left = rf(img.data, (y * img.w) * 4)
			local right = rf(img.data, (y * img.w + img.w - 1) * 4)
			for x = 0, math.min(a - x0, w) - 1 do
				wf(out.data, (y * w + x) * 4, left)
			end
			for x = math.max(b - x0, 0), w - 1 do
				wf(out.data, (y * w + x) * 4, right)
			end
		end
	end
	return out
end

-- Copy with every column outside [x0, x1) set to 0.
function M.maskColumns(img: Image, x0: number, x1: number): Image
	local out = M.new(img.w, img.h)
	local a, b = math.max(x0, 0), math.min(x1, img.w)
	if b > a then
		for y = 0, img.h - 1 do
			local o = (y * img.w + a) * 4
			buffer.copy(out.data, o, img.data, o, (b - a) * 4)
		end
	end
	return out
end

-- dst += src * scale
function M.add(dst: Image, src: Image, scale: number?)
	local s = scale or 1
	local d, sd = dst.data, src.data
	for o = 0, (dst.w * dst.h - 1) * 4, 4 do
		wf(d, o, rf(d, o) + rf(sd, o) * s)
	end
end

function M.square(img: Image): Image
	local out = M.new(img.w, img.h)
	local s, d = img.data, out.data
	for o = 0, (img.w * img.h - 1) * 4, 4 do
		local v = rf(s, o)
		wf(d, o, v * v)
	end
	return out
end

-- Centred box of radius r with replicated edges.
function M.hbox(src: Image, dst: Image, r: number)
	local w, h = src.w, src.h
	local s, d = src.data, dst.data
	local inv = 1 / (2 * r + 1)
	for y = 0, h - 1 do
		local row = y * w
		local acc = 0
		for k = -r, r do
			local x = if k < 0 then 0 elseif k >= w then w - 1 else k
			acc += rf(s, (row + x) * 4)
		end
		for x = 0, w - 1 do
			wf(d, (row + x) * 4, acc * inv)
			local xo = x - r
			if xo < 0 then
				xo = 0
			end
			local xi = x + r + 1
			if xi >= w then
				xi = w - 1
			end
			acc += rf(s, (row + xi) * 4) - rf(s, (row + xo) * 4)
		end
	end
end

function M.vbox(src: Image, dst: Image, r: number)
	local w, h = src.w, src.h
	local s, d = src.data, dst.data
	local inv = 1 / (2 * r + 1)
	for x = 0, w - 1 do
		local acc = 0
		for k = -r, r do
			local y = if k < 0 then 0 elseif k >= h then h - 1 else k
			acc += rf(s, (y * w + x) * 4)
		end
		for y = 0, h - 1 do
			wf(d, (y * w + x) * 4, acc * inv)
			local yo = y - r
			if yo < 0 then
				yo = 0
			end
			local yi = y + r + 1
			if yi >= h then
				yi = h - 1
			end
			acc += rf(s, (yi * w + x) * 4) - rf(s, (yo * w + x) * 4)
		end
	end
end

-- Gaussian approximation: three passes of a (2r+1) box in each direction.
function M.gauss3(src: Image, r: number): Image
	local a, b = M.new(src.w, src.h), M.new(src.w, src.h)
	M.hbox(src, a, r)
	M.vbox(a, b, r)
	M.hbox(b, a, r)
	M.vbox(a, b, r)
	M.hbox(b, a, r)
	M.vbox(a, b, r)
	return b
end

-- Mean of src over offsets 0..range in direction dir: dir = +1 means content
-- moved right, so out(x) averages src(x - o). Zero outside the image.
function M.dirBoxH(src: Image, range: number, dir: number): Image
	if range <= 0 then
		return M.copy(src)
	end
	local out = M.new(src.w, src.h)
	local w, h = src.w, src.h
	local s, d = src.data, out.data
	local inv = 1 / (range + 1)
	for y = 0, h - 1 do
		local row = y * w
		local acc = 0
		if dir >= 0 then
			for x = 0, w - 1 do
				acc += rf(s, (row + x) * 4)
				local xo = x - range - 1
				if xo >= 0 then
					acc -= rf(s, (row + xo) * 4)
				end
				wf(d, (row + x) * 4, acc * inv)
			end
		else
			for x = w - 1, 0, -1 do
				acc += rf(s, (row + x) * 4)
				local xo = x + range + 1
				if xo < w then
					acc -= rf(s, (row + xo) * 4)
				end
				wf(d, (row + x) * 4, acc * inv)
			end
		end
	end
	return out
end

-- Vertical counterpart of dirBoxH: dir = +1 means content moved down.
function M.dirBoxV(src: Image, range: number, dir: number): Image
	if range <= 0 then
		return M.copy(src)
	end
	local out = M.new(src.w, src.h)
	local w, h = src.w, src.h
	local s, d = src.data, out.data
	local inv = 1 / (range + 1)
	for x = 0, w - 1 do
		local acc = 0
		if dir >= 0 then
			for y = 0, h - 1 do
				acc += rf(s, (y * w + x) * 4)
				local yo = y - range - 1
				if yo >= 0 then
					acc -= rf(s, (yo * w + x) * 4)
				end
				wf(d, (y * w + x) * 4, acc * inv)
			end
		else
			for y = h - 1, 0, -1 do
				acc += rf(s, (y * w + x) * 4)
				local yo = y + range + 1
				if yo < h then
					acc -= rf(s, (yo * w + x) * 4)
				end
				wf(d, (y * w + x) * 4, acc * inv)
			end
		end
	end
	return out
end

-- Copy where columns [x0, x1) read from x + dx (clamped to the image).
function M.shiftColumns(img: Image, x0: number, x1: number, dx: number): Image
	local out = M.copy(img)
	if dx == 0 then
		return out
	end
	local w = img.w
	for y = 0, img.h - 1 do
		for x = math.max(x0, 0), math.min(x1, w) - 1 do
			local sx = x + dx
			if sx < 0 then
				sx = 0
			elseif sx >= w then
				sx = w - 1
			end
			wf(out.data, (y * w + x) * 4, rf(img.data, (y * w + sx) * 4))
		end
	end
	return out
end

-- Copy where every row y reads from y + dy (clamped).
function M.shiftRows(img: Image, dy: number): Image
	local out = M.new(img.w, img.h)
	local w, h = img.w, img.h
	for y = 0, h - 1 do
		local sy = y + dy
		if sy < 0 then
			sy = 0
		elseif sy >= h then
			sy = h - 1
		end
		buffer.copy(out.data, y * w * 4, img.data, sy * w * 4, w * 4)
	end
	return out
end

-- q-quantile (0..1) of the rows [y0, y1), via a 4096-bin histogram.
function M.percentile(img: Image, q: number, y0: number?, y1: number?): number
	local a, b = y0 or 0, y1 or img.h
	local lo, hi = math.huge, -math.huge
	for y = a, b - 1 do
		for x = 0, img.w - 1 do
			local v = rf(img.data, (y * img.w + x) * 4)
			if v < lo then
				lo = v
			end
			if v > hi then
				hi = v
			end
		end
	end
	if hi <= lo then
		return lo
	end
	local bins = 4096
	local counts = table.create(bins, 0)
	local scale = bins / (hi - lo)
	local n = 0
	for y = a, b - 1 do
		for x = 0, img.w - 1 do
			local i = math.floor((rf(img.data, (y * img.w + x) * 4) - lo) * scale)
			if i >= bins then
				i = bins - 1
			end
			counts[i + 1] += 1
			n += 1
		end
	end
	local target = q * n
	local acc = 0
	for i = 1, bins do
		acc += counts[i]
		if acc >= target then
			return lo + (i - 0.5) / scale
		end
	end
	return hi
end

function M.rgbNew(w: number, h: number): LinearRGB
	return { w = w, h = h, r = M.new(w, h), g = M.new(w, h), b = M.new(w, h) }
end

function M.rgbMap(lin: LinearRGB, fn: (Image) -> Image): LinearRGB
	local r, g, b = fn(lin.r), fn(lin.g), fn(lin.b)
	return { w = r.w, h = r.h, r = r, g = g, b = b }
end

function M.luma(lin: LinearRGB): Image
	local out = M.new(lin.w, lin.h)
	local r, g, b, d = lin.r.data, lin.g.data, lin.b.data, out.data
	for o = 0, (lin.w * lin.h - 1) * 4, 4 do
		wf(d, o, 0.2126 * rf(r, o) + 0.7152 * rf(g, o) + 0.0722 * rf(b, o))
	end
	return out
end

return M
