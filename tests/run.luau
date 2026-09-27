--!nonstrict
local t = require("./testlib")
local filter = ...

local modules = {
	"./labmodel_test",
	"./render_test",
	"./hotspots_test",
	"./exposure_test",
	"./schedule_test",
	"./optimize_test",
	"./simulate_test",
	"./scanstore_test",
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
