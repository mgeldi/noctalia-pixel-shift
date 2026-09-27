--!nonstrict
local t = require("./testlib")
local risk = require("../pixel-shift/core/risk")
local image = require("../pixel-shift/core/image")
local wear = require("../pixel-shift/core/wear")

t.test("risk: flat exposure has no risk", function()
	local E = image.new(30, 20)
	for y = 0, 19 do for x = 0, 29 do image.set(E, x, y, 1.5) end end
	local R = risk.map(E)
	t.near(image.get(R, 15, 10), 0, 1e-5)
end)

t.test("risk: reference equals the analytic line response", function()
	-- centre weights of three-pass boxes: width 3 -> 7/27, width 21 -> 331/9261
	local expected = 2.3 * ((1 - 7 / 27) + 0.5 * (1 - 331 / 9261))
	t.near(risk.reference(wear.PROFILES.generic), expected, 1e-4)
end)

t.test("risk: closed-form reference matches the measured line response", function()
	local p = wear.PROFILES.qdoled
	local E = image.new(128, 42)
	for x = 0, 127 do image.set(E, x, 20, wear.white(p)) end
	t.near(risk.reference(p), image.get(risk.map(E), 64, 20), 1e-4)
	t.near(risk.centerWeight(1), 7 / 27, 1e-12)
	t.near(risk.centerWeight(10), 331 / 9261, 1e-12)
end)

t.test("risk: histogram percentile and score", function()
	local R = image.new(100, 1)
	for x = 0, 99 do image.set(R, x, 0, x) end
	local h = risk.newHist(200)
	risk.accumulate(h, R, 0, 1, 0, 100)
	t.eq(h.n, 100)
	t.near(risk.percentile(h, 0.99), 98, 0.3) -- nearest rank, bin width 200/1024
	local flat = image.new(10, 1)
	for x = 0, 9 do image.set(flat, x, 0, 3) end
	local h2 = risk.newHist(6)
	risk.accumulate(h2, flat, 0, 1, 0, 10)
	t.near(risk.score(h2, 3), 100, 0.5)
	local h3 = risk.newHist(6)
	risk.accumulate(h3, flat, 0, 1, 0, 10)
	risk.merge(h2, h3)
	t.eq(h2.n, 20)
end)

return {}
