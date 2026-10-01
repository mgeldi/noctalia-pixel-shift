--!nonstrict
local t = require("./testlib")
local fullscreen = require("../pixel-shift/runtime/fullscreen")
local tasks = require("../pixel-shift/runtime/tasks")

-- tasks.waitFor reads the clock through the global host, which a luau module
-- cannot set for another one; these tests give it the fake clock instead.
local clock = { now = 0 }
local realWaitFor = tasks.waitFor
local function fakeWaitFor(pred: () -> boolean, timeoutMs: number): boolean
	local untilMs = clock.now + timeoutMs
	while not pred() do
		if clock.now >= untilMs then
			return false
		end
		coroutine.yield()
	end
	return true
end

local function test(name: string, fn: () -> ())
	t.test(name, function()
		tasks.waitFor = fakeWaitFor
		local ok, err = pcall(fn)
		tasks.waitFor = realWaitFor
		fullscreen.host = nil
		if not ok then
			error(err, 0)
		end
	end)
end

local MONITORS = '[{"id":1,"name":"DP-2"}]'
local CLIENTS = '[{"id":"c"}]'
local TREE = '{"type":"root"}'

-- A host whose runAsync waits for the test to deliver the process result.
local function fakeHost(vars, cmds)
	local h = { runs = {}, logs = {}, pending = {} }
	h.getenv = function(k)
		return vars[k]
	end
	h.commandExists = function(c)
		return cmds[c] == true
	end
	h.nowMs = function()
		return clock.now
	end
	h.log = function(m)
		table.insert(h.logs, m)
	end
	h.runAsync = function(argv, done, timeoutMs)
		table.insert(h.runs, { argv = argv, timeout = timeoutMs })
		table.insert(h.pending, done)
		return true
	end
	h.decoded = {
		[MONITORS] = { { id = 1, name = "DP-2", activeWorkspace = { id = 4 }, specialWorkspace = { id = 0 } } },
		[CLIENTS] = { { mapped = true, hidden = false, workspace = { id = 4 }, monitor = 1, fullscreen = 2 } },
		[TREE] = { type = "root", nodes = { { type = "output", name = "DP-3", nodes = { { type = "con", visible = true, fullscreen_mode = 1 } } } } },
	}
	h.json = {
		decode = function(s)
			local v = h.decoded[s]
			if v == nil then
				error("bad json")
			end
			return v
		end,
	}
	-- finish the oldest process
	h.finish = function(res)
		local done = table.remove(h.pending, 1)
		done(res)
	end
	return h
end

local function hypr()
	local h = fakeHost({ HYPRLAND_INSTANCE_SIGNATURE = "x" }, { hyprctl = true })
	fullscreen.reset()
	fullscreen.host = h
	clock.now = 10000
	return h
end

local function ok(stdout)
	return { exitCode = 0, stdout = stdout or (MONITORS .. "\n\n\n" .. CLIENTS .. "\n"), stderr = "", timedOut = false }
end

local function drain()
	for _ = 1, 20 do
		tasks.tick()
	end
end

test("fullscreen runtime: an unsupported compositor is never asked", function()
	local h = fakeHost({}, {})
	fullscreen.reset()
	fullscreen.host = h
	local got = nil
	tasks.spawn("q", function()
		got = fullscreen.query()
	end)
	drain()
	t.eq(fullscreen.kind(), nil)
	t.eq(next(got), nil)
	fullscreen.request()
	t.eq(tasks.running("fullscreen"), false)
	t.eq(#h.runs, 0)
end)

test("fullscreen runtime: one process answers, then the answer is reused until it is stale", function()
	local h = hypr()
	local got = nil
	tasks.spawn("q", function()
		got = fullscreen.query()
	end)
	drain()
	t.eq(#h.runs, 1)
	t.eq(table.concat(h.runs[1].argv, " "), "hyprctl --batch j/monitors;j/clients")
	t.eq(h.runs[1].timeout, 2000)
	t.eq(got, nil, "still waiting for the process")
	t.eq(fullscreen.fresh(), nil)
	h.finish(ok())
	drain()
	t.eq(got["DP-2"], true)
	t.ok(fullscreen.fresh() ~= nil)
	-- a second caller within the TTL gets the same answer without a process
	local again = nil
	tasks.spawn("q2", function()
		again = fullscreen.query()
	end)
	drain()
	t.eq(#h.runs, 1)
	t.eq(again["DP-2"], true)
	clock.now += fullscreen.TTL_MS + 1
	t.eq(fullscreen.fresh(), nil)
	tasks.spawn("q3", function()
		fullscreen.query()
	end)
	drain()
	t.eq(#h.runs, 2, "a stale answer is asked again")
	h.finish(ok())
	drain()
end)

test("fullscreen runtime: callers at the same time share one process", function()
	local h = hypr()
	local a, b = nil, nil
	tasks.spawn("a", function()
		a = fullscreen.query()
	end)
	tasks.spawn("b", function()
		b = fullscreen.query()
	end)
	drain()
	t.eq(#h.runs, 1)
	h.finish(ok())
	drain()
	t.eq(a["DP-2"], true)
	t.eq(b["DP-2"], true)
end)

test("fullscreen runtime: request starts a task once, and not while the answer is fresh", function()
	local h = hypr()
	fullscreen.request()
	fullscreen.request()
	t.eq(tasks.running("fullscreen"), true)
	drain()
	t.eq(#h.runs, 1)
	h.finish(ok())
	drain()
	t.eq(tasks.running("fullscreen"), false)
	t.ok(fullscreen.fresh() ~= nil)
	fullscreen.request()
	t.eq(tasks.running("fullscreen"), false, "fresh answer")
end)

test("fullscreen runtime: sway answers through the tree", function()
	local h = fakeHost({ SWAYSOCK = "/s" }, { swaymsg = true })
	fullscreen.reset()
	fullscreen.host = h
	clock.now = 10000
	local got = nil
	tasks.spawn("q", function()
		got = fullscreen.query()
	end)
	drain()
	t.eq(table.concat(h.runs[1].argv, " "), "swaymsg -r -t get_tree")
	h.finish(ok(TREE))
	drain()
	t.eq(got["DP-3"], true)
end)

test("fullscreen runtime: failures count as nothing covered and are logged once per streak", function()
	local h = hypr()
	local function run(res)
		local got = nil
		tasks.spawn("q", function()
			got = fullscreen.query()
		end)
		drain()
		h.finish(res)
		drain()
		clock.now += fullscreen.TTL_MS + 1
		return got
	end
	local got = run({ exitCode = 1, stdout = "", stderr = "no socket\n", timedOut = false })
	t.eq(next(got), nil)
	t.eq(#h.logs, 1)
	t.ok(string.find(h.logs[1], "no socket", 1, true) ~= nil, h.logs[1])
	run({ exitCode = 0, stdout = "", stderr = "", timedOut = true })
	run(ok("not json at all"))
	t.eq(#h.logs, 1, "same streak, no new line")
	got = run(ok())
	t.eq(got["DP-2"], true)
	run(nil)
	t.eq(#h.logs, 2, "a new streak is logged again")
	t.ok(string.find(h.logs[2], "could not start", 1, true) ~= nil, h.logs[2])
end)

test("fullscreen runtime: a failed answer is remembered so a step is not held up", function()
	local h = hypr()
	tasks.spawn("q", function()
		fullscreen.query()
	end)
	drain()
	h.finish({ exitCode = 1, stdout = "", stderr = "", timedOut = false })
	drain()
	local fresh = fullscreen.fresh()
	t.ok(fresh ~= nil)
	t.eq(next(fresh), nil)
end)

test("fullscreen runtime: a process that cannot start counts as no answer", function()
	local h = hypr()
	h.runAsync = function()
		return false
	end
	local got = nil
	tasks.spawn("q", function()
		got = fullscreen.query()
	end)
	drain()
	t.eq(next(got), nil)
	t.eq(#h.logs, 1)
end)

test("fullscreen runtime: a caller gives up waiting for a process that never answers", function()
	local h = hypr()
	local waiter, starter = nil, nil
	-- tasks are resumed newest first: the second one spawned asks, the first waits
	tasks.spawn("waiter", function()
		waiter = fullscreen.query()
	end)
	tasks.spawn("starter", function()
		starter = fullscreen.query()
	end)
	drain()
	t.eq(#h.runs, 1)
	t.eq(waiter, nil)
	clock.now += fullscreen.WAIT_MS + 1
	drain()
	t.eq(waiter ~= nil and next(waiter), nil, "the waiter behaves like today")
	t.eq(starter, nil, "the process itself is still running (the host times it out)")
	h.finish({ exitCode = 0, stdout = "", stderr = "", timedOut = true })
	drain()
	t.eq(next(starter), nil)
end)

test("fullscreen runtime: a host error does not leave the query stuck", function()
	local h = hypr()
	h.runAsync = function()
		error("boom")
	end
	local got = nil
	tasks.spawn("q", function()
		got = fullscreen.query()
	end)
	drain()
	t.eq(next(got), nil)
	t.ok(string.find(h.logs[1], "boom", 1, true) ~= nil, h.logs[1])
	clock.now += fullscreen.TTL_MS + 1
	h.runAsync = function(argv, done)
		table.insert(h.pending, done)
		return true
	end
	tasks.spawn("q2", function()
		got = fullscreen.query()
	end)
	drain()
	h.finish(ok())
	drain()
	t.eq(got["DP-2"], true)
end)

return {}
