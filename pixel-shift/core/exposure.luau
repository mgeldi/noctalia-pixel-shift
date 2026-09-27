--!nonstrict
-- Running exposure of the bar across the day: summed wear per profile (so
-- the panel profile can change later) plus luma sums for a variance map that
-- reveals dynamic content. Samples are stored un-shifted (home positions).

local image = require("./image.luau")
local wear = require("./wear.luau")

local budget = require("./budget.luau")

local M = {}
M.MAGIC = "PSX1"
local HEADER = "<c4I4I4I4dd"
local PLANES = { "generic", "woled", "qdoled", "lum", "lum2" }

function M.new(w: number, h: number)
	local acc = { w = w, h = h, n = 0, first = 0, last = 0, wear = {}, lum = image.new(w, h), lum2 = image.new(w, h) }
	for _, name in ipairs(wear.ORDER) do
		acc.wear[name] = image.new(w, h)
	end
	return acc
end

-- A capture where fewer than 1 % of pixels rise above 12/255: output off.
function M.isBlank(img): boolean
	local d = img.data
	local n = img.w * img.h
	local bright = 0
	for i = 0, n - 1 do
		if i % 1024 == 0 then
			budget.check()
		end
		local o = i * 3
		if buffer.readu8(d, o) > 12 or buffer.readu8(d, o + 1) > 12 or buffer.readu8(d, o + 2) > 12 then
			bright += 1
		end
	end
	return bright < n * 0.01
end

-- Does the capture still show the scanned bar? Mean luma difference over
-- the bar rows. Changing titles move it a little; a lock screen, a
-- fullscreen app or a new wallpaper move it a lot.
function M.matchesBaseline(capL, baseL, layout, tol: number?): boolean
	local sum, n = 0, 0
	for y = layout.barRows[1], layout.barRows[2] - 1 do
		budget.check()
		for x = 0, baseL.w - 1 do
			sum += math.abs(image.get(capL, x, y) - image.get(baseL, x, y))
			n += 1
		end
	end
	if n == 0 then
		return true
	end
	return sum / n < (tol or 0.06)
end

-- Undo the displacement active when the frame was captured: group gi's
-- content sits disp[gi] px right of home, and vRows rows along vDir.
function M.unshift(lin, layout, disp, vRows: number)
	local function fix(img)
		local out = img
		for gi, g in ipairs(layout.groups) do
			local d = disp[gi] or 0
			if d ~= 0 then
				out = image.shiftColumns(out, g.x0, g.x1, d)
			end
		end
		if vRows ~= 0 then
			out = image.shiftRows(out, vRows * layout.vDir)
		end
		return out
	end
	return image.rgbMap(lin, fix)
end

function M.add(acc, lin, t: number)
	for name, sum in pairs(acc.wear) do
		image.add(sum, wear.map(wear.profile(name), lin))
	end
	local L = image.luma(lin)
	image.add(acc.lum, L)
	image.add(acc.lum2, image.square(L))
	acc.n += 1
	if acc.n == 1 then
		acc.first = t
	end
	acc.last = t
end

local function scaled(img, s)
	local out = image.new(img.w, img.h)
	image.add(out, img, s)
	return out
end

function M.meanWear(acc, name: string)
	return scaled(acc.wear[name] or acc.wear.generic, 1 / math.max(acc.n, 1))
end

function M.variance(acc)
	local inv = 1 / math.max(acc.n, 1)
	local mean = scaled(acc.lum, inv)
	local out = scaled(acc.lum2, inv)
	image.add(out, image.square(mean), -1)
	return out
end

-- Simulation layers from the day's exposure: inside group columns the scan's
-- background plus the mean extra wear; elsewhere the mean wear itself.
function M.layers(acc, name: string, scan, layout)
	local mean = M.meanWear(acc, name)
	local wbg = image.copy(mean)
	local dw = image.new(mean.w, mean.h)
	for _, g in ipairs(layout.groups) do
		for y = 0, mean.h - 1 do
			budget.check()
			for x = math.max(g.x0, 0), math.min(g.x1, mean.w) - 1 do
				local b = image.get(scan.wbg, x, y)
				image.set(wbg, x, y, b)
				image.set(dw, x, y, image.get(mean, x, y) - b)
			end
		end
	end
	return { wbg = wbg, dw = dw }
end

local function planes(acc)
	return { acc.wear.generic, acc.wear.woled, acc.wear.qdoled, acc.lum, acc.lum2 }
end

function M.serialize(acc): string
	local parts = { string.pack(HEADER, M.MAGIC, acc.w, acc.h, acc.n, acc.first, acc.last) }
	for _, img in ipairs(planes(acc)) do
		table.insert(parts, buffer.tostring(img.data))
	end
	return table.concat(parts)
end

function M.deserialize(s: string?)
	if type(s) ~= "string" or #s < string.packsize(HEADER) then
		return nil
	end
	local magic, w, h, n, first, last, pos = string.unpack(HEADER, s)
	if magic ~= M.MAGIC or w <= 0 or h <= 0 then
		return nil
	end
	local plane = w * h * 4
	if #s ~= pos - 1 + #PLANES * plane then
		return nil
	end
	local acc = M.new(w, h)
	acc.n, acc.first, acc.last = n, first, last
	local src = buffer.fromstring(s)
	for _, img in ipairs(planes(acc)) do
		buffer.copy(img.data, 0, src, pos - 1, plane)
		pos += plane
	end
	return acc
end

return M
