--!nonstrict
local t = require("./testlib")
local probe = require("../pixel-shift/core/probe")

t.test("smoke: require across directories", function()
	t.eq(probe.hello(), "probe")
end)

return {}
