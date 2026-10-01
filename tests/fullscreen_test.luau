--!nonstrict
local t = require("./testlib")
local fs = require("../pixel-shift/core/fullscreen")

local function env(vars, cmds)
	return function(k)
		return vars[k]
	end, function(c)
		return cmds[c] == true
	end
end

t.test("fullscreen: the compositor comes from its environment and its tool", function()
	t.eq(fs.compositor(env({ HYPRLAND_INSTANCE_SIGNATURE = "abc" }, { hyprctl = true })), "hyprland")
	t.eq(fs.compositor(env({ SWAYSOCK = "/run/sway.sock" }, { swaymsg = true })), "sway")
	t.eq(fs.compositor(env({}, { hyprctl = true, swaymsg = true })), nil, "no session")
	t.eq(fs.compositor(env({ HYPRLAND_INSTANCE_SIGNATURE = "" }, { hyprctl = true })), nil, "empty variable")
	t.eq(fs.compositor(env({ HYPRLAND_INSTANCE_SIGNATURE = "abc" }, {})), nil, "no hyprctl")
	t.eq(fs.compositor(env({ SWAYSOCK = "/s" }, { hyprctl = true })), nil, "no swaymsg")
	t.eq(fs.compositor(env({ XDG_CURRENT_DESKTOP = "niri" }, {})), nil)
end)

t.test("fullscreen: each compositor is asked once, for everything it needs", function()
	t.eq(table.concat(fs.argv("hyprland"), " "), "hyprctl --batch j/monitors;j/clients")
	t.eq(table.concat(fs.argv("sway"), " "), "swaymsg -r -t get_tree")
end)

t.test("fullscreen: a hyprctl batch splits into its documents", function()
	local text = '[{\n    "id": 1,\n    "name": "DP-2"\n},{\n    "id": 0,\n    "name": "DP-3"\n}]\n\n\n[{\n    "mapped": true,\n    "title": "a\\n\\nb"\n}]\n'
	local docs = fs.splitBatch(text)
	t.eq(#docs, 2)
	t.eq(string.sub(docs[1], 1, 2), "[{")
	t.eq(string.sub(docs[1], -2), "}]")
	t.eq(string.find(docs[2], '"title": "a\\n\\nb"', 1, true) ~= nil, true, "escaped newlines stay inside")
	local empty = fs.splitBatch("[{\n \"id\": 1\n}]\n\n\n[]\n")
	t.eq(#empty, 2)
	t.eq(empty[2], "[]")
	t.eq(#fs.splitBatch(""), 0)
	t.eq(#fs.splitBatch("\n\n\n"), 0)
	t.eq(#fs.splitBatch("[]\r\n\r\n\r\n[]\r\n"), 2)
end)

local MONITORS = {
	{ id = 1, name = "DP-2", activeWorkspace = { id = 4, name = "4" }, specialWorkspace = { id = 0, name = "" } },
	{ id = 0, name = "DP-3", activeWorkspace = { id = 6, name = "6" }, specialWorkspace = { id = 0, name = "" } },
}

local function client(p)
	local c = { mapped = true, hidden = false, workspace = { id = 4, name = "4" }, monitor = 1, fullscreen = 0, fullscreenClient = 0 }
	for k, v in pairs(p) do
		c[k] = v
	end
	return c
end

t.test("fullscreen: hyprland, a fullscreen window on the shown workspace covers its monitor", function()
	local set = fs.hyprland(MONITORS, { client({ fullscreen = 2 }), client({ workspace = { id = 6 }, monitor = 0 }) })
	t.eq(set["DP-2"], true)
	t.eq(set["DP-3"], nil)
	t.eq(fs.any(set), true)
	t.eq(fs.names(set), "DP-2")
	t.eq(fs.names(fs.hyprland(MONITORS, { client({ fullscreen = 2 }), client({ fullscreen = 2, workspace = { id = 6 }, monitor = 0 }) })), "DP-2,DP-3")
end)

t.test("fullscreen: hyprland, maximized does not hide the bar, fullscreen+maximized does", function()
	t.eq(fs.any(fs.hyprland(MONITORS, { client({ fullscreen = 1 }) })), false)
	t.eq(fs.any(fs.hyprland(MONITORS, { client({ fullscreen = 0 }) })), false)
	t.eq(fs.hyprland(MONITORS, { client({ fullscreen = 3 }) })["DP-2"], true)
end)

t.test("fullscreen: hyprland, only what is shown counts", function()
	t.eq(fs.any(fs.hyprland(MONITORS, { client({ fullscreen = 2, workspace = { id = 9 } }) })), false, "inactive workspace")
	t.eq(fs.any(fs.hyprland(MONITORS, { client({ fullscreen = 2, hidden = true }) })), false, "hidden")
	t.eq(fs.any(fs.hyprland(MONITORS, { client({ fullscreen = 2, mapped = false }) })), false, "unmapped")
	t.eq(fs.any(fs.hyprland(MONITORS, { client({ fullscreen = 2, monitor = 7 }) })), false, "unknown monitor")
	-- a window of another monitor's workspace does not cover this one
	t.eq(fs.any(fs.hyprland(MONITORS, { client({ fullscreen = 2, monitor = 0 }) })), false, "workspace 4 is not shown on DP-3")
end)

t.test("fullscreen: hyprland, a shown special workspace covers its monitor", function()
	local mons = {
		{ id = 1, name = "DP-2", activeWorkspace = { id = 4 }, specialWorkspace = { id = -99, name = "special:magic" } },
		{ id = 0, name = "DP-3", activeWorkspace = { id = 6 }, specialWorkspace = { id = 0, name = "" } },
	}
	local set = fs.hyprland(mons, { client({ fullscreen = 2, workspace = { id = -99 } }) })
	t.eq(set["DP-2"], true)
	t.eq(fs.any(fs.hyprland(MONITORS, { client({ fullscreen = 2, workspace = { id = -99 } }) })), false, "special workspace not shown")
	t.eq(fs.any(fs.hyprland(mons, { client({ fullscreen = 2, workspace = { id = 0 }, monitor = 1 }) })), false, "id 0 is no workspace")
end)

t.test("fullscreen: hyprland, garbage in gives an empty set", function()
	t.eq(fs.any(fs.hyprland(nil, nil)), false)
	t.eq(fs.any(fs.hyprland("x", 3)), false)
	t.eq(fs.any(fs.hyprland(MONITORS, {})), false)
	t.eq(fs.any(fs.hyprland({}, { client({ fullscreen = 2 }) })), false)
	t.eq(fs.any(fs.hyprland({ 1, "a", {} }, { 1, "a", {}, { fullscreen = "2" }, { fullscreen = 2 } })), false)
	t.eq(fs.any(fs.hyprland(MONITORS, { { fullscreen = 2, monitor = 1 } })), false, "no workspace field")
	t.eq(fs.any(nil), false)
	t.eq(fs.names(nil), "")
	t.eq(fs.names({}), "")
end)

local function con(p)
	local c = { type = "con", name = "app", visible = true, fullscreen_mode = 0, nodes = {}, floating_nodes = {} }
	for k, v in pairs(p or {}) do
		c[k] = v
	end
	return c
end

local function output(name, workspaces)
	return { type = "output", name = name, nodes = workspaces, floating_nodes = {} }
end

local function workspace(name, cons, floating)
	return { type = "workspace", name = name, nodes = cons, floating_nodes = floating or {} }
end

local function tree(outputs)
	return { type = "root", name = "root", nodes = outputs, floating_nodes = {} }
end

local SCRATCH = output("__i3", { workspace("__i3_scratch", {}) })

t.test("fullscreen: sway, fullscreen_mode 1 covers only its own output", function()
	local set = fs.sway(tree({
		SCRATCH,
		output("DP-2", { workspace("1", { con({}), con({ fullscreen_mode = 1 }) }) }),
		output("DP-3", { workspace("2", { con({}) }) }),
	}))
	t.eq(set["DP-2"], true)
	t.eq(set["DP-3"], nil)
	t.eq(fs.names(set), "DP-2")
end)

t.test("fullscreen: sway, a window that is not visible is ignored", function()
	local set = fs.sway(tree({
		output("DP-2", { workspace("1", { con({ fullscreen_mode = 1, visible = false }) }) }),
	}))
	t.eq(fs.any(set), false)
end)

t.test("fullscreen: sway, global fullscreen covers every real output", function()
	local set = fs.sway(tree({
		SCRATCH,
		output("DP-2", { workspace("1", { con({ fullscreen_mode = 2 }) }) }),
		output("DP-3", { workspace("2", { con({}) }) }),
	}))
	t.eq(fs.names(set), "DP-2,DP-3", "the scratchpad output is not a monitor")
	local hidden = fs.sway(tree({
		output("DP-2", { workspace("1", { con({ fullscreen_mode = 2, visible = false }) }) }),
	}))
	t.eq(fs.any(hidden), false)
end)

t.test("fullscreen: sway, the scratchpad output is ignored", function()
	local set = fs.sway(tree({
		output("__i3", { workspace("__i3_scratch", { con({ fullscreen_mode = 1 }) }, { con({ fullscreen_mode = 2 }) }) }),
		output("DP-2", { workspace("1", { con({}) }) }),
	}))
	t.eq(fs.any(set), false)
end)

t.test("fullscreen: sway, a floating fullscreen window counts, nested containers too", function()
	local floating = con({ type = "floating_con", fullscreen_mode = 1 })
	local set = fs.sway(tree({
		output("DP-2", { workspace("1", { con({}) }, { floating }) }),
		output("DP-3", { workspace("2", { con({ nodes = { con({ fullscreen_mode = 1 }) } }) }) }),
	}))
	t.eq(fs.names(set), "DP-2,DP-3")
	t.eq(fs.any(fs.sway(nil)), false)
	t.eq(fs.any(fs.sway({})), false)
	t.eq(fs.any(fs.sway({ nodes = "x" })), false)
end)

return {}
