--!nonstrict
-- Opt-in vertical shift: an override file in the Noctalia config dir trades
-- margin for thickness, so the bar content moves while the reserved space
-- (and therefore every window) stays where it is.

local util = require("../core/util.luau")

local M = {}
M.FILE = "zz-pixel-shift.toml"

function M.path(): string
	return util.configDir(noctalia.getenv) .. "/" .. M.FILE
end

function M.active(): boolean
	return noctalia.fileExists(M.path())
end

local function reload()
	noctalia.runAsync({ "noctalia", "msg", "config-reload" })
end

-- base = {bar, margin, thickness}: the user's own values, read before the
-- override existed. v = content offset in logical px.
function M.apply(base, v: number): boolean
	if v <= 0 then
		return M.clear()
	end
	local ok = noctalia.writeFile(M.path(), util.verticalToml(base.bar, base.margin + 2 * v, base.thickness - 2 * v))
	if ok then
		reload()
	end
	return ok
end

function M.clear(): boolean
	if M.active() then
		noctalia.removeFile(M.path())
		reload()
	end
	return true
end

function M.effective(base, v: number): boolean
	return noctalia.getSetting(`bar.{base.bar}.margin_edge`) == base.margin + 2 * v
end

return M
