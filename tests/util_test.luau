--!nonstrict
local t = require("./testlib")
local util = require("../pixel-shift/core/util")

local function env(tbl)
	return function(k) return tbl[k] end
end

t.test("util: config dir precedence", function()
	t.eq(util.configDir(env({ NOCTALIA_CONFIG_HOME = "/n", XDG_CONFIG_HOME = "/x", HOME = "/h" })), "/n")
	t.eq(util.configDir(env({ XDG_CONFIG_HOME = "/x", HOME = "/h" })), "/x/noctalia")
	t.eq(util.configDir(env({ HOME = "/h" })), "/h/.config/noctalia")
end)

t.test("util: fnv1a and fingerprints", function()
	t.eq(util.fnv1a(""), "811c9dc5")
	t.eq(util.fnv1a("a"), "e40c292c")
	t.eq(util.fingerprint({ b = 1, a = { 2, 3 } }), util.fingerprint({ a = { 2, 3 }, b = 1 }))
	t.ok(util.fingerprint({ a = 1 }) ~= util.fingerprint({ a = 2 }))
	local id = util.randomId("x")
	t.eq(#id, 8)
	t.ok(util.randomId("x") ~= util.randomId("y"))
end)

t.test("util: capture geometry top, scale 1 and 1.5", function()
	local g = util.captureGeometry({ x = 0, y = 0, width = 2560, height = 1440, scale = 1 }, { position = "top", thickness = 34, margin = 0 })
	t.eq(g.geometry, "0,0 2560x42"); t.eq(g.barPx, 34); t.eq(g.flipped, false); t.eq(g.vDir, 1); t.eq(g.transpose, false)
	local h = util.captureGeometry({ x = 2560, y = 0, width = 2560, height = 1440, scale = 1.5 }, { position = "top", thickness = 34, margin = 0 })
	t.eq(h.geometry, "2560,0 2560x40"); t.eq(h.barPx, 51)
end)

t.test("util: capture geometry bottom, left, right", function()
	local out = { x = 0, y = 0, width = 2560, height = 1440, scale = 1 }
	local b = util.captureGeometry(out, { position = "bottom", thickness = 34, margin = 0 })
	t.eq(b.geometry, "0,1398 2560x42"); t.eq(b.flipped, true); t.eq(b.vDir, -1)
	local l = util.captureGeometry(out, { position = "left", thickness = 34, margin = 4 })
	t.eq(l.geometry, "4,0 42x1440"); t.eq(l.transpose, true); t.eq(l.flipped, false)
	local r = util.captureGeometry(out, { position = "right", thickness = 34, margin = 0 })
	t.eq(r.geometry, "2518,0 42x1440"); t.eq(r.transpose, true); t.eq(r.flipped, true)
end)

t.test("util: row layout", function()
	local bar, score = util.rowLayout(false, 42, 34)
	t.eq(bar[1], 0); t.eq(bar[2], 34); t.eq(score[1], 0); t.eq(score[2], 36)
	bar, score = util.rowLayout(true, 42, 34)
	t.eq(bar[1], 8); t.eq(bar[2], 42); t.eq(score[1], 6); t.eq(score[2], 42)
end)

t.test("util: registry pruning", function()
	local reg, changed = util.pruneRegistry({ a = { t = 100 }, b = { t = 10 } }, 150, 90)
	t.ok(reg.a ~= nil); t.eq(reg.b, nil); t.eq(changed, true)
	local _, same = util.pruneRegistry({ a = { t = 100 } }, 150, 90)
	t.eq(same, false)
end)

t.test("util: displacements and misc", function()
	local layout = { groups = { { factors = { a = 1 } }, { factors = { a = 0.5, b = -0.5 } } } }
	local d = util.displacements(layout, { a = 4, b = 2 })
	t.eq(d[1], 4); t.eq(d[2], 1)
	local toml = util.verticalToml("main", 2, 32)
	t.ok(string.find(toml, "[bar.main]", 1, true) ~= nil)
	t.ok(string.find(toml, "margin_edge = 2", 1, true) ~= nil)
	t.ok(string.find(toml, "thickness = 32", 1, true) ~= nil)
	t.eq(util.side(100, 2560), "left"); t.eq(util.side(1280, 2560), "center"); t.eq(util.side(2400, 2560), "right")
end)

return {}
