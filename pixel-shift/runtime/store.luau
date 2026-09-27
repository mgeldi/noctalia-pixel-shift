--!nonstrict
-- Persistence in the plugin data dir: JSON documents and binary blobs,
-- written atomically (temp file + rename), plus rendered lab images.

local M = {}

function M.dir(): string?
	local d = noctalia.pluginDataDir()
	return d
end

local function path(name: string): string?
	local d = M.dir()
	return if d then d .. "/" .. name else nil
end

function M.read(name: string): string?
	local p = path(name)
	if not p then
		return nil
	end
	local s = noctalia.readFile(p)
	return s
end

function M.write(name: string, data: string): boolean
	local p = path(name)
	if not p or not noctalia.writeFile(p .. ".tmp", data) then
		return false
	end
	local ok = noctalia.renameFile(p .. ".tmp", p)
	return ok
end

function M.readJson(name: string)
	local s = M.read(name)
	if not s then
		return nil
	end
	local v = noctalia.json.decode(s)
	return v
end

function M.writeJson(name: string, value): boolean
	local s = noctalia.json.encode(value, true)
	return s ~= nil and M.write(name, s)
end

function M.remove(name: string)
	local p = path(name)
	if p then
		noctalia.removeFile(p)
	end
end

-- Lab images live in memory-backed $XDG_RUNTIME_DIR when there is one (they
-- are rewritten often and worthless after a restart), else in the data dir.
M.KEEP_RENDERS = 16 -- files kept per image slot; the lab caches their paths

local function renderDir(): string?
	local run = noctalia.getenv("XDG_RUNTIME_DIR")
	if run and run ~= "" then
		return run .. "/pixel-shift-render"
	end
	local d = M.dir()
	return if d then d .. "/render" else nil
end

-- A new file name per render so ui.image never shows a cached old image.
local renders = {}
local counter = 0
function M.writeImage(slot: string, bytes: string): string?
	local dir = renderDir()
	if not dir then
		return nil
	end
	noctalia.mkdirAll(dir)
	counter += 1
	local name = `{dir}/{slot}-{os.time()}-{counter}.bmp`
	if not noctalia.writeFile(name, bytes) then
		return nil
	end
	local list = renders[slot] or {}
	renders[slot] = list
	table.insert(list, name)
	while #list > M.KEEP_RENDERS do
		noctalia.removeFile(table.remove(list, 1))
	end
	return name
end

function M.cleanRenders()
	local dirs = { renderDir() }
	local d = M.dir()
	if d then
		table.insert(dirs, d .. "/render") -- older versions wrote here
	end
	for _, dir in ipairs(dirs) do
		for _, f in ipairs(noctalia.listDir(dir) or {}) do
			noctalia.removeFile(if string.sub(f, 1, 1) == "/" then f else dir .. "/" .. f)
		end
	end
end

return M
