--!nonstrict
-- Spike stub (replaced in Task 19).
local probe = require("./core/probe.luau")
noctalia.log("pixel-shift engine stub: " .. probe.hello())

function onIpc(event, payload)
	if event == "spike-width" then
		noctalia.state.set("spike:w", tonumber(payload) or 0)
	elseif event == "spike-img" then
		noctalia.state.set("spike:img", payload)
	elseif event == "spike-state" then
		noctalia.state.set("spike:table", { a = 1, nested = { b = "x" }, list = { 1, 2, 3 } })
	elseif event == "spike-outputs" then
		for _, o in ipairs(noctalia.outputs()) do
			noctalia.log(`pixel-shift output {o.name} x={o.x} y={o.y} w={o.width} h={o.height} scale={o.scale}`)
		end
		noctalia.log("pixel-shift bar.order=" .. noctalia.json.encode(noctalia.getSetting("bar.order")) .. " scale=" .. tostring(noctalia.getSetting("bar.main.scale"))
			.. " api getColor=" .. tostring(noctalia.getColor ~= nil) .. " wallpaper=" .. tostring(noctalia.wallpaperPath("DP-2")))
	elseif event == "spike-setting" then
		noctalia.log("pixel-shift margin_edge=" .. tostring(noctalia.getSetting("bar.main.margin_edge"))
			.. " thickness=" .. tostring(noctalia.getSetting("bar.main.thickness")))
	end
end
