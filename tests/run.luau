--!nonstrict
local t = require("./testlib")
local filter = ...

local modules = {
	"./color_test",
	"./image_test",
}
for _, m in ipairs(modules) do
	require(m)
end

t.run(filter)
