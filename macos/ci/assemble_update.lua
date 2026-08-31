-- Assemble the post-update Lua tree the macOS app would have after the
-- in-app updater pulls a given upstream branch, without running the GUI.
--
--   luajit assemble_update.lua <factory_root> <upstream_root> <work_dir>
--
--   factory_root   wrapper's pinned PathOfBuilding submodule (the bundle's
--                  "factory default" tree)
--   upstream_root  checkout of the branch users update to (beta/dev)
--   work_dir       output; work_dir/src becomes the simulated App Support src
--
-- Simulation model: start from the factory src (what a fresh install has),
-- then overlay every file the upstream manifest would deliver, using the
-- same routing rules as mac_entry.lua's manifest filter:
--   * File runtime="win32"            -> not delivered (Windows binaries)
--   * part="runtime" name=lua/*.lua   -> delivered to src/lua/ (runtime_lua)
--   * part="runtime" anything else    -> NOT delivered; bundle-managed, so it
--                                        must already exist in the factory
--                                        runtime/ or the wrapper needs a new
--                                        DMG release -> hard failure here
--   * everything else                 -> delivered to src/<name>
-- If mac_entry.lua's filterPoBVersion changes, keep this routing in sync.
--
-- Approximations (documented, deliberate):
--   * Every manifest-listed file is overlaid, i.e. a full worst-case update
--     (the real updater skips files whose sha1 already matches).
--   * Files the updater would delete are left in place.
-- A manifest entry whose source file is missing upstream fails the run -
-- the real updater would 404 on it.
--
-- The factory base is hardlinked (cp -al), so overlay writes must remove the
-- destination before writing or they would corrupt the factory tree.

local factoryRoot, upstreamRoot, workDir = ...
assert(factoryRoot and upstreamRoot and workDir,
    "usage: luajit assemble_update.lua <factory_root> <upstream_root> <work_dir>")

package.path = upstreamRoot .. "/runtime/lua/?.lua;" .. upstreamRoot .. "/runtime/lua/?/init.lua"
local xml = require("xml")

local function fileExists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function shellQuote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local errors = {}
local function fail(fmt, ...)
    table.insert(errors, string.format(fmt, ...))
end

-- os.execute returns a number (5.1) or a boolean (LUA52COMPAT builds).
local function run(cmd)
    local r = os.execute(cmd)
    return r == 0 or r == true
end

-- Base tree: hardlink farm of the factory src.
assert(run(string.format("rm -rf %s/src && mkdir -p %s && cp -al %s/src %s/src",
    shellQuote(workDir), shellQuote(workDir), shellQuote(factoryRoot), shellQuote(workDir))),
    "failed to hardlink factory src into work dir")

local manifest = xml.LoadXMLFile(upstreamRoot .. "/manifest.xml")
assert(manifest and manifest[1] and manifest[1].elem == "PoBVersion",
    "could not parse " .. upstreamRoot .. "/manifest.xml")

-- Map each part to its path relative to the repo root, from the Source URLs
-- (".../{branch}/<relative>"). Unknown URL shapes are an error: the real
-- updater's download URLs would have moved too.
local partRoot = {}
for _, node in ipairs(manifest[1]) do
    if type(node) == "table" and node.elem == "Source" then
        local rel = node.attrib.url and node.attrib.url:match("{branch}/(.*)$")
        if rel then
            partRoot[node.attrib.part] = rel
        else
            fail("Source part=%q has unrecognized url %q", tostring(node.attrib.part), tostring(node.attrib.url))
        end
    end
end

local function deliver(srcPath, destName)
    if not fileExists(srcPath) then
        fail("manifest lists %q but it is missing upstream (updater would 404)", destName)
        return
    end
    local dest = workDir .. "/src/" .. destName
    local destDir = dest:match("^(.*)/[^/]+$")
    run("mkdir -p " .. shellQuote(destDir))
    local input = assert(io.open(srcPath, "rb"))
    local data = input:read("*a")
    input:close()
    os.remove(dest) -- never write through a factory hardlink
    local output = assert(io.open(dest, "wb"))
    output:write(data)
    output:close()
end

local delivered, checked = 0, 0
for _, node in ipairs(manifest[1]) do
    if type(node) == "table" and node.elem == "File" then
        local name, part = node.attrib.name, node.attrib.part
        if node.attrib.runtime and node.attrib.runtime ~= "macos" then
            -- Windows-only binary; never delivered on macOS.
        elseif part == "runtime" and name:match("^lua/.+%.lua$") then
            deliver(upstreamRoot .. "/runtime/" .. name, name)
            delivered = delivered + 1
        elseif part == "runtime" then
            if not fileExists(factoryRoot .. "/runtime/" .. name) then
                fail("new bundle-managed runtime file %q: the updater cannot deliver it on macOS, a wrapper release is needed", name)
            end
            checked = checked + 1
        else
            local root = partRoot[part]
            if not root then
                fail("File %q references part %q with no Source entry", name, tostring(part))
            else
                deliver(upstreamRoot .. "/" .. root .. name, name)
                delivered = delivered + 1
            end
        end
    end
end

-- The local manifest is written by UpdateCheck itself rather than listed as
-- a File entry. Ship the upstream one so Launch.lua sees the tested version;
-- its Version node carries no branch/platform, which puts the boot in dev
-- mode (updates disabled) - the same environment upstream's headless CI runs
-- in, and it keeps the canary off the network.
deliver(upstreamRoot .. "/manifest.xml", "manifest.xml")

-- Consumed on first boot; the post-update state never has it.
os.remove(workDir .. "/src/first.run")

if #errors > 0 then
    print(string.format("assemble_update: %d problem(s):", #errors))
    for _, e in ipairs(errors) do print("  " .. e) end
    os.exit(1)
end
print(string.format("assemble_update: OK (%d files delivered, %d bundle-managed files verified)", delivered, checked))
