--!nonstrict
-- Noctalia stops a script callback after ~25 ms of CPU. Heavy core work must
-- therefore offer yield points: with a slicing hook installed, a full-size
-- risk map (the most expensive step) has to finish in slices well under that.
local t = require("./testlib")
local budget = require("../pixel-shift/core/budget")
local image = require("../pixel-shift/core/image")
local risk = require("../pixel-shift/core/risk")
local render = require("../pixel-shift/core/render")
local color = require("../pixel-shift/core/color")

local function sliced(fn)
	local sliceStart = os.clock()
	local longest = 0
	budget.hook = function()
		if (os.clock() - sliceStart) * 1000 >= 4 and coroutine.isyieldable() then
			coroutine.yield()
		end
	end
	local co = coroutine.create(fn)
	local slices = 0
	while coroutine.status(co) ~= "dead" do
		sliceStart = os.clock()
		local ok, err = coroutine.resume(co)
		assert(ok, err)
		longest = math.max(longest, (os.clock() - sliceStart) * 1000)
		slices += 1
	end
	budget.hook = nil
	return slices, longest
end

t.test("budget: check() is a no-op without a hook", function()
	budget.hook = nil
	budget.check()
	t.ok(true)
end)

t.test("budget: a full risk map and glow render yield in short slices", function()
	local E = image.new(2560, 42)
	for y = 0, 41 do
		for x = 0, 2559 do
			image.set(E, x, y, ((x * 7 + y * 13) % 17) / 17)
		end
	end
	local slices, longest = sliced(function()
		local R = risk.map(E)
		render.ghostView(E, R, 1, 1, color.glowRamp("#c1c5de"))
	end)
	t.ok(slices > 5, `expected several slices, got {slices}`)
	t.ok(longest < 20, `longest slice {longest} ms must stay well under Noctalia's ~25 ms budget`)
end)

return {}
