--!nonstrict
-- Spike stub (replaced in Task 20): shows a BMP to test image reloads.
local path = nil

local function render()
	panel.render(ui.column({ gap = 8 }, {
		ui.label({ text = "Pixel Shift spike " .. noctalia.json.encode(noctalia.state.get("spike:table")) }),
		ui.image({ path = path, width = 400, height = 60, fit = "stretch" }),
	}))
end

noctalia.state.watch("spike:img", function(v)
	path = v
	render()
end)

function onOpen()
	path = noctalia.state.get("spike:img")
	render()
end
