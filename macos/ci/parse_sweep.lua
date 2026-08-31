-- Compile-check every .lua file under the given roots with the running
-- interpreter, so syntax the shipped runtime cannot parse is caught even in
-- files the headless boot never loads (most Classes/ load lazily via
-- getClass on first use).
--
--   luajit parse_sweep.lua <root> [<root> ...]

local roots = { ... }
assert(#roots > 0, "usage: luajit parse_sweep.lua <root> [<root> ...]")

local function shellQuote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local count, failures = 0, {}
for _, root in ipairs(roots) do
    local find = assert(io.popen("find " .. shellQuote(root) .. " -type f -name '*.lua'"))
    for path in find:lines() do
        count = count + 1
        local chunk, err = loadfile(path)
        if not chunk then
            table.insert(failures, err)
        end
    end
    find:close()
end

if #failures > 0 then
    print(string.format("parse_sweep: %d of %d files failed to compile:", #failures, count))
    for _, err in ipairs(failures) do print("  " .. err) end
    os.exit(1)
end
print(string.format("parse_sweep: OK (%d files compiled)", count))
