--!nonstrict
local t = require("./testlib")
local image = require("../pixel-shift/core/image")
local layout = require("../pixel-shift/core/layout")
local wear = require("../pixel-shift/core/wear")

local W, H = 240, 12

-- luma image: background 0.1, bright blocks {x0, x1} on rows 3..8, moved by dx
local function scene(blocks, dx, noise)
	local img = image.new(W, H)
	for y = 0, H - 1 do for x = 0, W - 1 do image.set(img, x, y, 0.1) end end
	for _, b in ipairs(blocks) do
		for y = 3, 8 do
			for x = b[1] + dx, b[2] + dx - 1 do image.set(img, x, y, 0.8) end
		end
	end
	if noise then
		for y = 0, H - 1 do for x = noise[1], noise[2] - 1 do image.set(img, x, y, 0.1 + 0.3 * ((x + y) % 2)) end end
	end
	return img
end

local function opts(probes, scale, probePx)
	return {
		base = scene({ { 40, 44 }, { 60, 92 } }, 0),
		probes = probes,
		probePx = probePx or 8,
		scale = scale or 1,
		barRows = { 0, 10 },
		scoreRows = { 0, 12 },
		vDir = 1,
		maxShift = 16,
	}
end

t.test("layout: one spacer moving a cluster", function()
	local l = layout.build(opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 8) }))
	t.eq(#l.groups, 1)
	local g = l.groups[1]
	t.near(g.factors.a, 1, 1e-9)
	t.ok(g.x0 <= 40 and g.x1 >= 100, "group covers both positions")
	t.eq(g.own0, 0); t.eq(g.own1, W)
	t.eq(g.x1, W, "a right-moving group extends to its right boundary")
	t.ok(g.c0 <= 40 and g.c1 >= 100 and g.c1 < W, "content extent kept before the extension")
	t.eq(l.slots.a.moves, true)
end)

t.test("layout: fractional scale gives physical factors", function()
	local l = layout.build(opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 12) }, 1.5, 8))
	t.near(l.groups[1].factors.a, 1.5, 1e-9)
end)

t.test("layout: spacer that moves nothing is reported", function()
	local l = layout.build(opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 8), b = scene({ { 40, 44 }, { 60, 92 } }, 0) }))
	t.eq(l.slots.b.moves, false)
	t.eq(l.slots.a.moves, true)
end)

t.test("layout: centre spacers merge into one group with opposite factors", function()
	local l = layout.build(opts({
		l = scene({ { 40, 44 }, { 60, 92 } }, 4),
		r = scene({ { 40, 44 }, { 60, 92 } }, -4),
	}))
	t.eq(#l.groups, 1)
	t.near(l.groups[1].factors.l, 0.5, 1e-9)
	t.near(l.groups[1].factors.r, -0.5, 1e-9)
end)

-- scene with a separate shift per block (a widget that changed width moves the rest)
local function sceneShifts(blocks, shifts)
	local img = image.new(W, H)
	for y = 0, H - 1 do for x = 0, W - 1 do image.set(img, x, y, 0.1) end end
	for i, b in ipairs(blocks) do
		for y = 3, 8 do
			for x = b[1] + shifts[i], b[2] + shifts[i] - 1 do image.set(img, x, y, 0.8) end
		end
	end
	return img
end

-- an icon, then a title (text strokes) after a gap
-- irregular stroke spacing, so no shift maps the title onto itself
local ICON_TITLE = { { 40, 44 }, { 70, 72 }, { 75, 77 }, { 81, 83 }, { 88, 90 }, { 92, 94 }, { 99, 101 } }

local function shifts(icon, title)
	local list = { icon }
	for _ = 2, #ICON_TITLE do
		table.insert(list, title)
	end
	return list
end

t.test("layout: a widget changing width between captures is caught, not measured", function()
	-- the icon moves with the spacer (8 px), the title only 6 px: the CPU text before it shrank
	local o = opts({ a = sceneShifts(ICON_TITLE, shifts(8, 6)) })
	o.base = sceneShifts(ICON_TITLE, shifts(0, 0))
	local l, _, implausible = layout.build(o)
	t.eq(#implausible, 1)
	t.eq(implausible[1], "a")
	for _, g in ipairs(l.groups) do
		t.ok(math.abs((g.factors.a or 1) - 0.75) > 1e-6, "no factor from the bogus 6 px shift")
	end
end)

t.test("layout: a spacer whose content moves by the full and by half the width is measured again", function()
	-- a width change of 4 px makes the title look like centre content
	local o = opts({ a = sceneShifts(ICON_TITLE, shifts(8, 4)) })
	o.base = sceneShifts(ICON_TITLE, shifts(0, 0))
	local _, _, again = layout.build(o)
	t.eq(#again, 1)
	t.eq(again[1], "a")
	local centre = layout.build(opts({ c = sceneShifts({ { 40, 44 }, { 60, 92 } }, { -4, 4 }) }))
	t.ok(centre.slots.c.moves, "a centre spacer moving content both ways is fine")
	local _, _, none = layout.build(opts({ c = sceneShifts({ { 40, 44 }, { 60, 92 } }, { -4, 4 }) }))
	t.eq(#none, 0)
end)

t.test("layout: a sliver next to changing text cannot set the factor of a whole section", function()
	-- a 1 px sliver right of the CPU digits looks like it moved 4 px; the icons
	-- and the long title after it moved the full 8 px
	local blocks = { { 40, 41 }, { 60, 64 }, { 100, 180 } }
	local o = opts({ a = sceneShifts(blocks, { 4, 8, 8 }) })
	o.base = sceneShifts(blocks, { 0, 0, 0 })
	local l, _, again = layout.build(o)
	for _, g in ipairs(l.groups) do
		if g.factors.a then
			t.near(g.factors.a, 1, 1e-9, "the section moves by the full width")
		end
	end
	t.eq(#again, 0, "a small minority is outvoted, not measured again")
end)

t.test("layout: content that seems to move against its end spacer is dropped", function()
	-- the end spacer pushes its section left; a changing visualizer looks like +8
	local blocks = { { 120, 124 }, { 160, 166 }, { 200, 230 } }
	local o = opts({ e = sceneShifts(blocks, { -8, 8, -8 }) })
	o.base = sceneShifts(blocks, { 0, 0, 0 })
	local l, _, again = layout.build(o)
	for _, g in ipairs(l.groups) do
		t.ok((g.factors.e or -1) < 0, `no group moves right with the end spacer ({g.c0}-{g.c1})`)
	end
	t.eq(again[1], "e", "and it is measured again")
end)

t.test("layout: the capture with all spacers widened vetoes a spurious spacer", function()
	-- centre spacer c moves the centre block by 4; changing content in the end
	-- section happened to move by 4 while c was probed; end spacer e moves it by -8
	local blocks = { { 40, 50 }, { 150, 190 } }
	local o = opts({})
	o.base = sceneShifts(blocks, { 0, 0 })
	o.probes = { c = sceneShifts(blocks, { 4, 4 }), e = sceneShifts(blocks, { 0, -8 }) }
	o.all = sceneShifts(blocks, { 4, -8 })
	local l, _, again = layout.build(o)
	local endGroup = nil
	for _, g in ipairs(l.groups) do
		if g.c0 <= 150 and g.c1 >= 182 then
			endGroup = g
		end
	end
	t.ok(endGroup ~= nil)
	t.eq(endGroup.factors.c, nil, "the centre spacer does not move end content")
	t.near(endGroup.factors.e, -1, 1e-9)
	t.ok(table.find(again, "c") ~= nil)
end)

t.test("layout: each probe is compared with the base taken just before it", function()
	-- the shared base shows the title elsewhere; slot b's own base matches its probe
	local shared = scene({ { 40, 44 }, { 60, 92 } }, 0)
	local titleMoved = scene({ { 40, 44 }, { 150, 182 } }, 0)
	local o = opts({})
	o.base = shared
	o.probes = nil
	o.pairs = {
		a = { base = shared, probe = scene({ { 40, 44 }, { 60, 92 } }, 8) },
		b = { base = titleMoved, probe = scene({ { 40, 44 }, { 150, 182 } }, -8) },
	}
	local l, _, implausible = layout.build(o)
	t.eq(#implausible, 0)
	t.eq(l.slots.a.moves, true)
	t.eq(l.slots.b.moves, true)
	local fb = nil
	for _, g in ipairs(l.groups) do
		if g.factors.b then fb = g.factors.b end
	end
	t.near(fb, -1, 1e-9)
end)

t.test("layout: measured shifts snap to the spacer's exact factor", function()
	-- scale 1.25: a spacer widened by 8 px moves content 10 px; rounding can show 11
	local l = layout.build(opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 11) }, 1.25, 8))
	t.near(l.groups[1].factors.a, 1.25, 1e-9)
	local c = layout.build(opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 5) }, 1.25, 8))
	t.near(c.groups[1].factors.a, 0.625, 1e-9, "centre spacers move content half as far")
end)

t.test("layout: dynamic columns never create groups", function()
	local o = opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 8, { 180, 190 }) })
	o.baseB = scene({ { 40, 44 }, { 60, 92 } }, 0, { 180, 190 })
	o.base = scene({ { 40, 44 }, { 60, 92 } }, 0, { 181, 191 })
	local l = layout.build(o)
	t.eq(#l.groups, 1)
	t.ok(#l.dynamic >= 1)
end)

t.test("layout: background interpolates under content, layers isolate it", function()
	local l, diff = layout.build(opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 8) }))
	local lin = image.rgbNew(W, H)
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local bgv = 0.05 + 0.1 * x / W -- gentle gradient
			local v = if y >= 3 and y <= 7 and x >= 60 and x < 92 then 0.8 else bgv
			image.set(lin.r, x, y, v); image.set(lin.g, x, y, v); image.set(lin.b, x, y, v)
		end
	end
	local bg, content = layout.background(lin, l, diff)
	t.near(image.get(bg.g, 75, 5), 0.05 + 0.1 * 75 / W, 0.01)
	t.eq(image.get(content, 75, 5), 1)
	t.eq(image.get(content, 150, 5), 0)
	local layers = layout.layers(wear.PROFILES.generic, lin, bg)
	t.ok(image.get(layers.dw, 75, 5) > 0.5)
	t.near(image.get(layers.dw, 150, 5), 0, 1e-6)
end)

t.test("layout: verify accepts the right model and rejects a wrong one", function()
	local base = scene({ { 40, 44 }, { 60, 92 } }, 0)
	local l = layout.build(opts({ a = scene({ { 40, 44 }, { 60, 92 } }, 8) }))
	local bgL = scene({}, 0)
	t.ok(layout.verify(l, base, bgL, scene({ { 40, 44 }, { 60, 92 } }, 8)) < 0.05)
	t.ok(layout.verify(l, base, bgL, scene({ { 40, 44 }, { 60, 92 } }, 2)) > 0.35)
end)

return {}
