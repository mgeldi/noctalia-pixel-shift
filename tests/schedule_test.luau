--!nonstrict
local t = require("./testlib")
local schedule = require("../pixel-shift/core/schedule")

t.test("schedule: triangle walks 1 px at a time with uniform dwell", function()
	local seq = {}
	for k = 0, 7 do table.insert(seq, schedule.triangle(k * 10, 10, 3)) end
	t.eq(table.concat(seq, ","), "0,1,2,3,3,2,1,0")
	t.eq(schedule.triangle(80, 10, 3), 0)
	t.eq(schedule.triangle(123, 10, 0), 0)
end)

t.test("schedule: step intervals and offsets", function()
	t.near(schedule.stepSeconds(4, 1), 240, 1e-9)
	t.near(schedule.stepSeconds(4, 2), 276.96, 1e-9)
	t.near(schedule.stepSeconds(4, 9), 240, 1e-9)
	local o = schedule.offsets({ ranges = { a = 2, b = 0 } }, { "a", "b" }, 720, 4)
	t.eq(o.a, 2); t.eq(o.b, 0)
	t.eq(schedule.VERTICAL_STEP, 1800) -- spike S4: fewer config reloads
	t.eq(schedule.vertical(2, 3600), 2)
end)

return {}
