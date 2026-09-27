--!nonstrict
-- Minimal test framework for the standalone luau CLI.
local M = { tests = {} }

function M.test(name: string, fn: () -> ())
	table.insert(M.tests, { name = name, fn = fn })
end

local function fail(msg: string)
	error(msg, 3)
end

function M.eq(actual, expected, msg: string?)
	if actual ~= expected then
		fail(`{msg or "values differ"}: expected {tostring(expected)}, got {tostring(actual)}`)
	end
end

function M.near(actual: number, expected: number, tol: number?, msg: string?)
	local t = tol or 1e-6
	if type(actual) ~= "number" or math.abs(actual - expected) > t then
		fail(`{msg or "not near"}: expected {expected} ± {t}, got {tostring(actual)}`)
	end
end

function M.ok(value, msg: string?)
	if not value then
		fail(msg or "expected a truthy value")
	end
end

function M.run(filter: string?)
	local passed, failed = 0, 0
	for _, t in ipairs(M.tests) do
		if filter == nil or filter == "" or string.find(t.name, filter, 1, true) then
			local ok, err = pcall(t.fn)
			if ok then
				passed += 1
			else
				failed += 1
				print(`FAIL {t.name}\n     {tostring(err)}`)
			end
		end
	end
	print(`{passed} passed, {failed} failed`)
	if failed > 0 then
		error("test failures", 0)
	end
end

return M
