--!nonstrict
local t = require("./testlib")
local decide = require("../pixel-shift/core/decide")

local MOVING = { slots = { a = { moves = true }, b = { moves = false } } }
local IDLE = { slots = { a = { moves = false } } }

t.test("decide: retry backoff doubles and is capped", function()
	t.eq(decide.backoff(1), 60)
	t.eq(decide.backoff(2), 120)
	t.eq(decide.backoff(3), 240)
	t.eq(decide.backoff(12), 3600)
end)

t.test("decide: a scan where nothing moves never replaces a good scan", function()
	t.eq(decide.acceptScan(IDLE, true), false, "covered bar must not become the baseline")
	t.eq(decide.acceptScan(IDLE, false), true, "first scan is kept so the lab can explain it")
	t.eq(decide.acceptScan(MOVING, true), true)
end)

t.test("decide: only layouts with a moving spacer may auto-apply", function()
	t.eq(decide.autoApply(MOVING), true)
	t.eq(decide.autoApply(IDLE), false)
	t.eq(decide.autoApply({}), false)
end)

t.test("decide: strategy identity ignores key order", function()
	t.eq(decide.sameStrategy({ ranges = { a = 1, b = 2 }, vertical = 0 }, { ranges = { b = 2, a = 1 }, vertical = 0 }), true)
	t.eq(decide.sameStrategy({ ranges = { a = 1 }, vertical = 0 }, { ranges = { a = 1 }, vertical = 1 }), false)
	t.eq(decide.sameStrategy({ ranges = { a = 1 }, vertical = 0 }, { ranges = { a = 1, b = 3 }, vertical = 0 }), false)
	t.eq(decide.sameStrategy(nil, { ranges = {}, vertical = 0 }), false)
end)

t.test("decide: every accepted scan with a moving spacer re-optimizes", function()
	local o = decide.scanOutcome(MOVING, true, 1)
	t.eq(o.accept, true)
	t.eq(o.optimize, true)
	t.eq(o.retryIn, nil)
end)

t.test("decide: a covered rescan keeps the old scan and retries later", function()
	local o = decide.scanOutcome(IDLE, true, 2)
	t.eq(o.accept, false)
	t.eq(o.optimize, false)
	t.eq(o.retryIn, 120)
end)

t.test("decide: a first scan where nothing moves is kept, not optimized, and retried", function()
	local o = decide.scanOutcome(IDLE, false, 1)
	t.eq(o.accept, true)
	t.eq(o.optimize, false)
	t.eq(o.retryIn, 60)
end)

t.test("decide: three mismatches that agree with each other trigger a rescan", function()
	local n, rescan = decide.mismatch(0, false)
	t.eq(n, 1)
	t.eq(rescan, false)
	n, rescan = decide.mismatch(n, true)
	t.eq(n, 2)
	n, rescan = decide.mismatch(n, true)
	t.eq(rescan, true)
	t.eq(n, 0)
	n, rescan = decide.mismatch(2, false) -- a different picture starts over
	t.eq(n, 1)
	t.eq(rescan, false)
end)

t.test("decide: IPC commands fall back to the first output", function()
	local outs = { ["DP-3"] = {}, ["DP-2"] = {} }
	t.eq(decide.pickOutput(nil, outs), "DP-2")
	t.eq(decide.pickOutput("DP-3", outs), "DP-3")
	t.eq(decide.pickOutput("HDMI-1", outs), "DP-2")
	t.eq(decide.pickOutput(nil, {}), nil)
end)

t.test("decide: the vertical player holds while a scan runs and re-applies after it", function()
	local base = { scanning = false, allowed = true, paused = false, v = 1, last = 1, fileActive = true, driftDue = false }
	local function with(p)
		local st = table.clone(base)
		for k, v in pairs(p) do
			st[k] = v
		end
		return st
	end
	local action, last = decide.verticalAction(with({ scanning = true, v = 2 }))
	t.eq(action, "hold")
	t.eq(last, -1, "the next tick after the scan applies again")
	t.eq(decide.verticalAction(with({ last = -1 })), "apply")
	t.eq(decide.verticalAction(with({ v = 2 })), "apply")
	t.eq(decide.verticalAction(base), "none")
	t.eq(decide.verticalAction(with({ fileActive = false, driftDue = true })), "apply", "repair a deleted file")
	t.eq(decide.verticalAction(with({ fileActive = false })), "none", "repairs wait for the drift check")
	t.eq(decide.verticalAction(with({ allowed = false })), "clear")
	t.eq(decide.verticalAction(with({ paused = true, fileActive = false })), "none")
end)

t.test("decide: the vertical base is refreshed only while no override is in effect", function()
	local old = { bar = "main", margin = 0, thickness = 34 }
	local bar = { name = "main", margin = 4, rawThickness = 40 }
	t.eq(decide.verticalBase(old, bar, true, true), old, "override file present")
	t.eq(decide.verticalBase(old, bar, false, false), old, "config not settled yet")
	local fresh = decide.verticalBase(old, bar, false, true)
	t.eq(fresh.margin, 4)
	t.eq(fresh.thickness, 40)
	t.eq(fresh.bar, "main")
	t.eq(decide.verticalBase(fresh, bar, false, true), fresh, "unchanged values keep the table")
	t.eq(decide.verticalBase(nil, bar, false, true).thickness, 40)
end)

t.test("decide: the exposure file is written every few samples, not every sample", function()
	t.eq(decide.persistExposure(1), true)
	t.eq(decide.persistExposure(2), false)
	t.eq(decide.persistExposure(5), false)
	t.eq(decide.persistExposure(6), true)
	t.eq(decide.persistExposure(12), true)
end)

t.test("decide: the auto run uses the protection level of the applied strategy", function()
	t.eq(decide.autoLevel({ ranges = {}, vertical = 0, lambdaT = 0.2 }, 0.9), 0.2)
	t.eq(decide.autoLevel({ ranges = {}, vertical = 0 }, 0.9), 0.9)
	t.eq(decide.autoLevel(nil, 0.4), 0.4)
end)

t.test("decide: saved layouts need the current format", function()
	local base = { w = 10, h = 4 }
	t.eq(decide.validLayout({ format = decide.LAYOUT_FORMAT, w = 10, h = 4, groups = {}, slots = {}, barRows = { 0, 3 }, scoreRows = { 0, 4 } }, base), true)
	t.eq(decide.validLayout({ w = 10, h = 4, groups = {}, slots = {}, barRows = { 0, 3 }, scoreRows = { 0, 4 } }, base), false, "no format")
	t.eq(decide.validLayout({ format = decide.LAYOUT_FORMAT, w = 12, h = 4, groups = {}, slots = {}, barRows = { 0, 3 }, scoreRows = { 0, 4 } }, base), false, "size")
	t.eq(decide.validLayout({ format = decide.LAYOUT_FORMAT, w = 10, h = 4, slots = {}, barRows = { 0, 3 }, scoreRows = { 0, 4 } }, base), false, "groups")
	t.eq(decide.validLayout(nil, base), false)
end)

t.test("decide: misplaced spacers are named with the section they belong to", function()
	local function isSpacer(n)
		return string.sub(n, 1, 3) == "ps_"
	end
	t.eq(#decide.placement({ start = { "ps_a", "clock" }, center = { "ps_b", "title", "ps_c" }, ["end"] = { "tray", "ps_d" } }, isSpacer), 0)
	local issues = decide.placement({ start = { "clock", "ps_a" }, center = { "ps_b", "title" }, ["end"] = { "ps_d", "tray" } }, isSpacer)
	t.eq(#issues, 2)
	t.eq(issues[1].widget, "ps_a")
	t.eq(issues[1].want, "start")
	t.eq(issues[2].widget, "ps_d")
	t.eq(issues[2].want, "end")
	local mid = decide.placement({ start = {}, center = { "a", "ps_m", "b" }, ["end"] = {} }, isSpacer)
	t.eq(mid[1].want, "center")
end)

return {}
