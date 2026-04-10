-- macOS bundle entry point.
--
-- The bundle's launcher binary points the SimpleGraphic Lua engine at this
-- file instead of Launch.lua so we can install a manifest filter on the
-- in-app updater BEFORE upstream code starts running.
--
-- Why this exists:
--   PoB's updater (UpdateCheck.lua) reads a manifest.xml that lists every
--   shipped file with platform metadata. Upstream marks Windows binaries
--   with runtime="win32" but does NOT actually filter on that attribute
--   anywhere in the Lua code. Without intervention, the updater would
--   try to download libEGL.dll, lcurl.dll, Path of Building.exe, etc.
--   from raw.githubusercontent.com on every check and crash on the runtime
--   source URL lookup (which is keyed by platform="win32").
--
-- Strategy:
--   We monkey-patch xml.LoadXMLFile and xml.ParseXML to strip win32-only
--   file entries and re-key the runtime source URL from platform="win32"
--   to platform="macos" so the cross-platform runtime/* files (Lua modules,
--   fonts) still update from upstream's raw URL but the Windows-only
--   binaries become invisible to the updater entirely.
--
-- Two installation points are needed because UpdateCheck runs in two places:
--   1. The first-run path (Launch.lua line ~37) calls LoadModule("UpdateCheck")
--      which reuses the main Lua state. Patching xml here covers this case.
--   2. The regular Ctrl+U / 12-hour path (Launch.lua launch:CheckForUpdate)
--      uses LaunchSubScript with a fresh Lua state, so we wrap the global
--      LaunchSubScript and prepend the same patches into the sub-script's
--      source text before it's compiled in the sub-state.
--
-- This file is installed at src/mac_entry.lua but is NOT listed in any
-- manifest (local or remote). The upstream updater therefore never tracks,
-- updates, or deletes it.

local function filterPoBVersion(doc)
    if type(doc) ~= "table" or not doc[1] or doc[1].elem ~= "PoBVersion" then
        return doc
    end
    local root = doc[1]
    local filtered = { elem = "PoBVersion", attrib = root.attrib }
    for _, node in ipairs(root) do
        local keep = true
        if type(node) == "table" then
            if node.elem == "File" and node.attrib.runtime and node.attrib.runtime ~= "macos" then
                -- Drop Windows-only binaries (.dll, .exe).
                keep = false
            elseif node.elem == "File" and node.attrib.part == "runtime" then
                -- Cross-platform "runtime" file (e.g. lua/dkjson.lua, fonts
                -- under SimpleGraphic/Fonts/). Upstream marks these
                -- part="runtime" because they live in runtime/ in the PoB
                -- Lua repo, but functionally they're regular data files.
                -- We drop them from the manifest entirely on macOS for two
                -- reasons:
                --   1. UpdateCheck.lua flips updateMode to "basic" for ANY
                --      part="runtime" file, which on macOS would call
                --      SpawnProcess(runtimePath/Update, ...) — we don't
                --      ship an Update helper binary, so basic-mode would
                --      fail forever.
                --   2. We can't simply re-categorize them as "program"
                --      because that would route the download URL through
                --      <repo>/master/src/ instead of <repo>/master/runtime/
                --      and change the on-disk destination from Resources/
                --      to Resources/src/.
                -- They're shipped in the DMG, sit on disk, and get
                -- refreshed only when a new DMG is released. These files
                -- are extremely stable upstream (years between changes),
                -- so this is acceptable.
                keep = false
            elseif node.elem == "Source" and node.attrib.platform and node.attrib.platform ~= "macos" then
                -- Re-key Windows-only source URLs to macos so the platform-keyed
                -- partSources lookup in UpdateCheck.lua resolves. The cross-platform
                -- files served from this URL (runtime/lua/*, runtime/SimpleGraphic/*)
                -- live at the same upstream raw URL regardless of target platform.
                local copy = { elem = "Source", attrib = {} }
                for k, v in pairs(node.attrib) do copy.attrib[k] = v end
                copy.attrib.platform = "macos"
                table.insert(filtered, copy)
                keep = false
            end
        end
        if keep then
            table.insert(filtered, node)
        end
    end
    doc[1] = filtered
    return doc
end

-- Patch xml in the main Lua state. Used by the first-run install path
-- (Launch.lua line ~37: LoadModule("UpdateCheck") runs in the main state).
do
    local xml = require("xml")
    local origLoadXMLFile = xml.LoadXMLFile
    xml.LoadXMLFile = function(...)
        return filterPoBVersion(origLoadXMLFile(...))
    end
    local origParseXML = xml.ParseXML
    xml.ParseXML = function(...)
        return filterPoBVersion(origParseXML(...))
    end
end

-- Patch LaunchSubScript so the regular CheckForUpdate path (which spawns
-- UpdateCheck in a fresh sub-script Lua state) also gets the filter. We
-- can't share the patched xml table across Lua states, so we inject the
-- patches as a source-level preamble that the sub-script runs first.
do
    local subPreamble = [==[
local function filterPoBVersion(doc)
    if type(doc) ~= "table" or not doc[1] or doc[1].elem ~= "PoBVersion" then
        return doc
    end
    local root = doc[1]
    local filtered = { elem = "PoBVersion", attrib = root.attrib }
    for _, node in ipairs(root) do
        local keep = true
        if type(node) == "table" then
            if node.elem == "File" and node.attrib.runtime and node.attrib.runtime ~= "macos" then
                keep = false
            elseif node.elem == "File" and node.attrib.part == "runtime" then
                -- Drop cross-platform runtime files entirely. See main-state
                -- filter above for why we don't re-categorize them.
                keep = false
            elseif node.elem == "Source" and node.attrib.platform and node.attrib.platform ~= "macos" then
                local copy = { elem = "Source", attrib = {} }
                for k, v in pairs(node.attrib) do copy.attrib[k] = v end
                copy.attrib.platform = "macos"
                table.insert(filtered, copy)
                keep = false
            end
        end
        if keep then
            table.insert(filtered, node)
        end
    end
    doc[1] = filtered
    return doc
end
local xml = require("xml")
local origLoadXMLFile = xml.LoadXMLFile
xml.LoadXMLFile = function(...) return filterPoBVersion(origLoadXMLFile(...)) end
local origParseXML = xml.ParseXML
xml.ParseXML = function(...) return filterPoBVersion(origParseXML(...)) end
]==]

    local origLaunchSubScript = LaunchSubScript
    LaunchSubScript = function(scriptText, funcList, subList, ...)
        if type(scriptText) == "string" and scriptText:find("Checking for update", 1, true) then
            -- UpdateCheck.lua starts with "#@" which Lua's loader only
            -- accepts at byte 0 (shebang skip). We're about to prepend our
            -- preamble in front of it, so the # would no longer be at the
            -- start. Strip the leading shebang-style line first.
            scriptText = scriptText:gsub("^#[^\n]*\n", "")
            scriptText = subPreamble .. scriptText
        end
        return origLaunchSubScript(scriptText, funcList, subList, ...)
    end
end

-- Hand off to upstream Launch.lua. cwd at this point is src/ (set by the
-- launcher → sys_main → SetWorkDir from our entry script's path), so a
-- relative dofile resolves correctly.
dofile("Launch.lua")
