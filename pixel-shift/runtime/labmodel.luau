--!nonstrict
-- Builds everything the lab shows for one output: evaluations (cached per
-- strategy), the rendered images, hotspots and curve data. Text is left to
-- the lab; this module only produces numbers, enums and image paths.

local image = require("../core/image.luau")
local color = require("../core/color.luau")
local render = require("../core/render.luau")
local bmp = require("../core/bmp.luau")
local hotspots = require("../core/hotspots.luau")
local simulate = require("../core/simulate.luau")
local optimize = require("../core/optimize.luau")
local util = require("../core/util.luau")
local wear = require("../core/wear.luau")
local store = require("./store.luau")

local M = {}

M.OVERVIEW_W = 860
M.INSPECT_W = 560
M.INSPECT_MAX_H = 170

local function hex(c)
	return string.format("#%02x%02x%02x", c[1], c[2], c[3])
end

function M.evaluate(O, strategy)
	O.evalCache = O.evalCache or {}
	O.evalOrder = O.evalOrder or {}
	local key = `{O.layersId}|{util.stableEncode(strategy.ranges)}|{strategy.vertical or 0}`
	local hit = O.evalCache[key]
	if hit then
		return hit
	end
	local ev = simulate.evaluate(O.layers, O.layout, strategy, O.rref)
	O.evalCache[key] = ev
	table.insert(O.evalOrder, key)
	if #O.evalOrder > 6 then
		O.evalCache[table.remove(O.evalOrder, 1)] = nil
	end
	return ev
end

-- Label key for a spacer: the side of the group it moves, and for groups
-- moved by two spacers (the centre) which side the spacer sits on.
function M.slotLabel(layout, slot): string
	for _, g in ipairs(layout.groups) do
		local f = g.factors[slot]
		if f then
			local count = 0
			for _ in pairs(g.factors) do
				count += 1
			end
			local side = util.side(((g.c0 or g.own0) + (g.c1 or g.own1)) / 2, layout.w)
			if count > 1 then
				return if f > 0 then "center_l" else "center_r"
			end
			return side
		end
	end
	return "unknown"
end

local function sortedSlots(layout)
	local list = {}
	for slot in pairs(layout.slots) do
		table.insert(list, slot)
	end
	table.sort(list)
	return list
end

function M.build(O, ui, ctx)
	local write = ctx.writeImage or store.writeImage
	local layout = O.layout
	local y0, y1 = layout.scoreRows[1], layout.scoreRows[2]
	local none = { ranges = {}, vertical = 0 }
	local evNone = M.evaluate(O, none)
	local evStrat = M.evaluate(O, ctx.preview)
	local eRef = image.percentile(evNone.E, 0.998, y0, y1)
	local rTop = image.percentile(evNone.R, 0.999, y0, y1)
	local ramp = color.glowRamp(ctx.primary)
	local glow = hex(ramp[205])

	local function view(ev)
		if ui.view == "risk" then
			return render.riskView(image.luma(O.base), ev.R, rTop, color.riskRamp(ctx.primary))
		elseif ui.view == "bar" then
			return O.lastCapture or render.fromLinear(O.base)
		end
		return render.ghostView(ev.E, ev.R, eRef, rTop, ramp)
	end
	local fullNone, fullStrat = view(evNone), view(evStrat)
	local shown = if ui.mode == "none" then fullNone else fullStrat

	local spots = hotspots.find({
		R = evStrat.R,
		dw = O.layers.dw,
		wWhite = wear.white(wear.profile(ctx.profile)),
		variance = O.variance,
		layout = layout,
		rref = O.rref,
		strategy = ctx.preview,
	})
	local selected = math.clamp(ui.hotspot or 1, 1, math.max(#spots, 1))
	local sel = spots[selected]

	-- inspector region: centred on the selected hotspot (or the bar centre)
	local zoom = math.clamp(M.INSPECT_MAX_H // layout.h, 1, 4)
	local regionW = M.INSPECT_W // zoom
	local cx = if sel then (sel.x0 + sel.x1) // 2 else layout.w // 2
	local rx0 = math.clamp(cx - regionW // 2, 0, math.max(layout.w - regionW, 0))
	local rx1 = math.min(rx0 + regionW, layout.w)

	-- overview halves with the inspected region framed
	local half = layout.w // 2
	local framed = render.zoom(shown, 0, shown.w, 0, shown.h, 1)
	render.frame(framed, rx0, rx1, ramp[230])
	local left, right = render.halves(framed, M.OVERVIEW_W)
	local scale = M.OVERVIEW_W / half
	local pins = {}
	for i, s in ipairs(spots) do
		local x = (s.x0 + s.x1) / 2
		local row = if x < half then 1 else 2
		table.insert(pins, { n = i, row = row, x = (x - (if row == 2 then half else 0)) * scale, selected = i == selected })
	end

	local data = {
		glow = glow,
		info = O.info,
		exposure = { n = if O.acc then O.acc.n else 0, hours = if O.acc and O.acc.n > 1 then (O.acc.last - O.acc.first) / 3600 else 0 },
		score = { none = evNone.score, strategy = evStrat.score },
		approximate = O.approximate,
		overview = {
			left = write("overview-l", bmp.encode(left)),
			right = write("overview-r", bmp.encode(right)),
			w = M.OVERVIEW_W,
			h = left.h,
			pins = pins,
		},
		inspector = {
			none = write("inspect-none", bmp.encode(render.zoom(fullNone, rx0, rx1, 0, layout.h, zoom))),
			strategy = write("inspect-strategy", bmp.encode(render.zoom(fullStrat, rx0, rx1, 0, layout.h, zoom))),
			w = (rx1 - rx0) * zoom,
			h = layout.h * zoom,
			zoom = zoom,
			n = if sel then selected else nil,
		},
		legend = write("legend", bmp.encode(render.legend(ramp, 120, 8))),
		hotspots = {},
		chips = {},
		manual = {},
		idle = {},
		vertical = ctx.preview.vertical or 0,
		stepMinutes = ctx.stepMinutes,
		maxShift = ctx.maxShift,
		previewing = ctx.previewing,
		canRevert = ctx.canRevert,
	}
	for i, s in ipairs(spots) do
		data.hotspots[i] = { n = i, side = s.side, x0 = s.x0, x1 = s.x1, cause = s.cause, peak = s.peak }
	end
	for _, slot in ipairs(sortedSlots(layout)) do
		local label = M.slotLabel(layout, slot)
		if layout.slots[slot].moves then
			local px = ctx.preview.ranges[slot] or 0
			table.insert(data.chips, { slot = label, px = px })
			table.insert(data.manual, { id = slot, slot = label, value = px })
		else
			table.insert(data.idle, label)
		end
	end
	if ctx.result then
		local r = ctx.result
		local c = optimize.curve(r.entries, r.budgets)
		local top = math.max(evNone.score, 1)
		local h, v = {}, {}
		for i = 1, #r.budgets do
			h[i] = math.clamp((c.h[i] or top) / (top * 1.05), 0, 1)
			if c.v[i] then
				v[i] = math.clamp(c.v[i] / (top * 1.05), 0, 1)
			end
		end
		local pick = optimize.pick(r.entries, optimize.lambdaFromSlider(ctx.lambdaT), ctx.allowVertical and r.allowVertical)
		local pickIndex = nil
		for i, B in ipairs(r.budgets) do
			if pick and pick.B == B then
				pickIndex = i
			end
		end
		data.curve = {
			h = h,
			v = if #v == #r.budgets then v else nil,
			budgets = r.budgets,
			pick = pickIndex,
			pickScore = pick and pick.score or nil,
			pickLambdaT = ctx.lambdaT,
		}
		data.status = { at = r.at, evals = r.evals, seconds = r.seconds }
	end
	return data
end

return M
