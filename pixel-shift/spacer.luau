--!nonstrict
-- Spike stub (replaced in Task 17): width from shared state key "spike:w".
local width = noctalia.state.get("spike:w") or 0

local function render()
	barWidget.render(ui.box({ width = width, height = 1, fill = "#00000000" }))
end

noctalia.state.watch("spike:w", function(v)
	width = tonumber(v) or 0
	render()
end)

render()
