--!nonstrict
local t = require("./testlib")
local filter = ...

local modules = {
	"./layout_test",
	"./util_test",
	"./risk_test",
	"./wear_test",
	"./raster_test",
	"./color_test",
	"./image_test",
}
for _, m in ipairs(modules) do
	require(m)
end

t.run(filter)
