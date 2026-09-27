--!nonstrict
-- Visible burn-in risk: wear that differs from its neighbourhood, at a fine
-- scale (strokes, icon edges) and a coarse scale (blocks, band edges).

local image = require("./image.luau")
local wear = require("./wear.luau")

local rf, wf = buffer.readf32, buffer.writef32

local M = {}

M.FINE_R = 1
M.COARSE_R = 10
M.COARSE_W = 0.5
M.BINS = 1024

export type Hist = { bins: { number }, n: number, cap: number }

function M.map(E: image.Image): image.Image
	local g1 = image.gauss3(E, M.FINE_R)
	local g2 = image.gauss3(E, M.COARSE_R)
	local R = image.new(E.w, E.h)
	local e, a, b, r = E.data, g1.data, g2.data, R.data
	local cw = M.COARSE_W
	for o = 0, (E.w * E.h - 1) * 4, 4 do
		local v = rf(e, o)
		wf(r, o, math.abs(v - rf(a, o)) + cw * math.abs(v - rf(b, o)))
	end
	return R
end

-- Risk of a 1 px pure-white line on black without shifting: the 100 mark.
function M.reference(p): number
	local w, h = 128, 42
	local E = image.new(w, h)
	local v = wear.white(p)
	for x = 0, w - 1 do
		image.set(E, x, 20, v)
	end
	return image.get(M.map(E), w // 2, 20)
end

function M.newHist(cap: number): Hist
	return { bins = table.create(M.BINS, 0), n = 0, cap = cap }
end

function M.accumulate(h: Hist, R: image.Image, y0: number, y1: number, x0: number, x1: number)
	local scale = M.BINS / h.cap
	local bins = h.bins
	local top = M.BINS - 1
	local a, b = math.max(x0, 0), math.min(x1, R.w)
	for y = math.max(y0, 0), math.min(y1, R.h) - 1 do
		local row = y * R.w
		for x = a, b - 1 do
			local i = math.floor(rf(R.data, (row + x) * 4) * scale)
			if i > top then
				i = top
			elseif i < 0 then
				i = 0
			end
			bins[i + 1] += 1
		end
		h.n += math.max(b - a, 0)
	end
end

function M.merge(dst: Hist, src: Hist)
	assert(dst.cap == src.cap, "histogram caps differ")
	local d, s = dst.bins, src.bins
	for i = 1, M.BINS do
		d[i] += s[i]
	end
	dst.n += src.n
end

function M.percentile(h: Hist, q: number): number
	if h.n == 0 then
		return 0
	end
	local target = q * h.n
	local acc = 0
	local width = h.cap / M.BINS
	for i = 1, M.BINS do
		acc += h.bins[i]
		if acc >= target then
			return (i - 0.5) * width
		end
	end
	return h.cap
end

function M.score(h: Hist, rref: number): number
	return 100 * M.percentile(h, 0.99) / rref
end

return M
