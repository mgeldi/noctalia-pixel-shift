--!nonstrict
local t = require("./testlib")
local vertical = require("../pixel-shift/runtime/vertical")

local function fakeHost(settings)
	local h = { files = {}, calls = {}, now = 0 }
	h.getenv = function(k)
		return if k == "XDG_CONFIG_HOME" then "/cfg" else nil
	end
	h.fileExists = function(p)
		return h.files[p] ~= nil
	end
	h.writeFile = function(p, c)
		table.insert(h.calls, "write " .. p)
		h.files[p] = c
		return true
	end
	h.renameFile = function(a, b)
		table.insert(h.calls, "rename " .. a .. " " .. b)
		h.files[b], h.files[a] = h.files[a], nil
		return true
	end
	h.removeFile = function(p)
		table.insert(h.calls, "remove " .. p)
		h.files[p] = nil
		return true
	end
	h.runAsync = function(argv)
		table.insert(h.calls, "run " .. table.concat(argv, " "))
		return true
	end
	h.nowMs = function()
		return h.now
	end
	h.getSetting = function(k)
		return settings[k]
	end
	return h
end

local BASE = { bar = "main", margin = 0, thickness = 34 }

t.test("vertical: the override is written atomically and reloads by itself", function()
	local h = fakeHost({})
	vertical.host = h
	vertical.apply(BASE, 1)
	t.eq(h.calls[1], "write /cfg/noctalia/zz-pixel-shift.toml.tmp")
	t.eq(h.calls[2], "rename /cfg/noctalia/zz-pixel-shift.toml.tmp /cfg/noctalia/zz-pixel-shift.toml")
	t.eq(#h.calls, 2, "Noctalia reloads on the rename; no extra config-reload")
	vertical.clear()
	t.eq(h.calls[3], "remove /cfg/noctalia/zz-pixel-shift.toml")
	t.eq(h.calls[4], "run noctalia msg config-reload", "a delete is not watched, so it needs a reload")
	vertical.host = nil
end)

t.test("vertical: a thickness overridden elsewhere is noticed", function()
	vertical.host = fakeHost({ ["bar.main.margin_edge"] = 2, ["bar.main.thickness"] = 34 })
	t.eq(vertical.effective(BASE, 1), false)
	vertical.host = fakeHost({ ["bar.main.margin_edge"] = 2, ["bar.main.thickness"] = 32 })
	t.eq(vertical.effective(BASE, 1), true)
	vertical.host = nil
end)

t.test("vertical: the config counts as settled a few seconds after a change", function()
	local h = fakeHost({})
	vertical.host = h
	h.now = 100000
	t.eq(vertical.settled(), true)
	vertical.apply(BASE, 1)
	t.eq(vertical.settled(), false)
	h.now += vertical.SETTLE_MS
	t.eq(vertical.settled(), true)
	vertical.host = nil
end)

return {}
