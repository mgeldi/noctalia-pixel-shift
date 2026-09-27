--!nonstrict
-- Spike stub (replaced in Task 19).
local probe = require("./core/probe.luau")
noctalia.log("pixel-shift engine stub: " .. probe.hello())

function onIpc(event, payload)
	if event == "spike-width" then
		noctalia.state.set("spike:w", tonumber(payload) or 0)
	elseif event == "spike-state" then
		noctalia.state.set("spike:table", { a = 1, nested = { b = "x" }, list = { 1, 2, 3 } })
	elseif event == "spike-setting" then
		noctalia.log("pixel-shift margin_edge=" .. tostring(noctalia.getSetting("bar.main.margin_edge"))
			.. " thickness=" .. tostring(noctalia.getSetting("bar.main.thickness")))
	end
end
