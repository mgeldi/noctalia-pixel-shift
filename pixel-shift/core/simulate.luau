--!nonstrict
-- Strategy -> exposure -> risk. A group's content layer (its share of dw) is
-- box-blurred once per spacer that moves it; vertical shift blurs all group
-- content along rows. The static background never moves.

local image = require("./image.luau")
local risk = require("./risk.luau")

local M = {}

M.CONTEXT = 40 -- px each side of a group window: coarse blur reach + fine

export type Strategy = { ranges: { [string]: number }, vertical: number }

function M.kernels(group, ranges)
	local ks = {}
	for slot, f in pairs(group.factors) do
		local r = math.floor((ranges[slot] or 0) * math.abs(f) + 0.5)
		if r > 0 then
			table.insert(ks, { r, if f >= 0 then 1 else -1 })
		end
	end
	table.sort(ks, function(a, b)
		if a[1] ~= b[1] then
			return a[1] > b[1]
		end
		return a[2] > b[2]
	end)
	return ks
end

function M.kernelKey(ks): string
	local parts = table.create(#ks)
	for _, k in ipairs(ks) do
		table.insert(parts, tostring(k[1] * k[2]))
	end
	return table.concat(parts, ",")
end

function M.vRows(layout, V: number?): number
	return math.floor((V or 0) * layout.scale + 0.5)
end

local function groupContent(dw, x0, x1, ks)
	local layer = image.maskColumns(dw, x0, x1)
	for _, k in ipairs(ks) do
		layer = image.dirBoxH(layer, k[1], k[2])
	end
	return layer
end

function M.exposure(layers, layout, strategy: Strategy)
	local content = image.new(layers.dw.w, layers.dw.h)
	for _, g in ipairs(layout.groups) do
		image.add(content, groupContent(layers.dw, g.x0, g.x1, M.kernels(g, strategy.ranges)))
	end
	local vr = M.vRows(layout, strategy.vertical)
	if vr > 0 then
		content = image.dirBoxV(content, vr, layout.vDir)
	end
	local E = image.copy(layers.wbg)
	image.add(E, content)
	return E
end

function M.evaluate(layers, layout, strategy: Strategy, rref: number)
	local E = M.exposure(layers, layout, strategy)
	local R = risk.map(E)
	local h = risk.newHist(2 * rref)
	risk.accumulate(h, R, layout.scoreRows[1], layout.scoreRows[2], 0, R.w)
	return { E = E, R = R, hist = h, score = risk.score(h, rref) }
end

-- Risk histogram over one group's ownership columns, computed on a window.
function M.groupHist(layers, layout, gi: number, ranges, V: number, rref: number)
	local g = layout.groups[gi]
	local a, b = g.own0 - M.CONTEXT, g.own1 + M.CONTEXT
	local E = image.crop(layers.wbg, a, b, "clamp")
	local dw = image.crop(layers.dw, a, b)
	local content = groupContent(dw, g.x0 - a, g.x1 - a, M.kernels(g, ranges))
	local vr = M.vRows(layout, V)
	if vr > 0 then
		content = image.dirBoxV(content, vr, layout.vDir)
	end
	image.add(E, content)
	local R = risk.map(E)
	local h = risk.newHist(2 * rref)
	risk.accumulate(h, R, layout.scoreRows[1], layout.scoreRows[2], g.own0 - a, g.own1 - a)
	return h
end

-- Histogram of every column no group owns. Strategy-independent: nothing
-- there moves horizontally, and vertical shift only moves group content.
function M.staticHist(layers, layout, rref: number)
	local R = risk.map(layers.wbg)
	local h = risk.newHist(2 * rref)
	local y0, y1 = layout.scoreRows[1], layout.scoreRows[2]
	local cursor = 0
	for _, g in ipairs(layout.groups) do
		if g.own0 > cursor then
			risk.accumulate(h, R, y0, y1, cursor, g.own0)
		end
		cursor = math.max(cursor, g.own1)
	end
	if cursor < R.w then
		risk.accumulate(h, R, y0, y1, cursor, R.w)
	end
	return h
end

return M
