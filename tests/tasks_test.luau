--!nonstrict
local t = require("./testlib")
local tasks = require("../pixel-shift/runtime/tasks")

t.test("tasks: a failing task reports its error to its owner", function()
	local got = nil
	tasks.spawn("scan:X", function()
		error("probe size changed")
	end, function(err)
		got = err
	end)
	t.eq(tasks.runningPrefix("scan:"), true)
	tasks.tick()
	t.ok(got ~= nil and string.find(tostring(got), "probe size changed", 1, true) ~= nil)
	t.eq(tasks.active(), false)
	t.eq(tasks.runningPrefix("scan:"), false)
end)

return {}
