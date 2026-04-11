-- macOS bundle entry point.
--
-- The bundle's launcher binary points the SimpleGraphic Lua engine at this
-- file instead of Launch.lua so we can apply two patches to the in-app
-- updater BEFORE any upstream code runs.
--
-- Patch 1: manifest filter
--   PoB's updater (UpdateCheck.lua) reads a manifest.xml that lists every
--   shipped file. Upstream marks Windows binaries with runtime="win32" but
--   does NOT actually filter on that attribute anywhere in the Lua code.
--   Without intervention, the updater would try to download libEGL.dll,
--   lcurl.dll, Path of Building.exe, etc. from raw.githubusercontent.com
--   and crash on the runtime source URL lookup. We monkey-patch
--   xml.LoadXMLFile and xml.ParseXML to strip win32-only file entries,
--   drop cross-platform part="runtime" files (which would otherwise
--   trigger basic-mode updates that require an external Update helper
--   binary we don't ship), and re-key Windows-only source URLs to
--   platform="macos".
--
-- Patch 2: UpdateCheck.lua MakeDir loop fix for POSIX absolute paths
--   UpdateCheck.lua creates destination directories before downloading
--   with a per-segment loop:
--       local dirStr = ""
--       for dir in data.fullPath:gmatch("([^/]+/)") do
--           dirStr = dirStr .. dir
--           MakeDir(dirStr)
--       end
--   On Windows this works because fullPath starts with a drive letter
--   ("C:/..."), gmatch captures it, and the accumulated dirStr stays
--   absolute. On POSIX absolute paths ("/private/tmp/..."), the leading
--   "/" is skipped by Lua's [^/]+ pattern, the accumulated dirStr ends
--   up being RELATIVE, MakeDir resolves it against cwd, and the loop
--   creates a phantom directory tree under cwd while the real absolute
--   destination is never created. UpdateApply.lua then spins forever
--   at 100% CPU in its io.open retry loop.
--
--   We gsub the `local dirStr = ""` initialization into a conditional
--   form that seeds dirStr with "/" when fullPath is POSIX-absolute.
--   The rest of the loop is unchanged — per-segment MakeDir with the
--   singular l_MakeDir works fine once dirStr has the right prefix,
--   because each iteration's parent is the previous iteration's result.
--   The fix is a one-line change and makes no assumptions about
--   SimpleGraphic's MakeDir implementation. See UPSTREAM_NOTES.md at
--   the wrapper repo root for the upstreamable bug report.
--
-- Both patches need two installation points because UpdateCheck runs in
-- two places:
--   a. The first-run path (Launch.lua line ~37) calls LoadModule("UpdateCheck")
--      in the main Lua state. We wrap LoadModule globally, read the file
--      ourselves, apply the source patch, and compile via load().
--   b. The regular CheckForUpdate path (Launch.lua:85 background check on
--      startup + 12-hour timer + Ctrl+U) uses LaunchSubScript with a
--      fresh Lua state. We wrap LaunchSubScript, gsub the broken loop,
--      and prepend an xml-filter preamble into the sub-script's source
--      text before it's compiled in the sub-state.
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

-- Fix UpdateCheck.lua's per-segment MakeDir loop on POSIX absolute paths.
--
-- Upstream code:
--     local dirStr = ""
--     for dir in data.fullPath:gmatch("([^/]+/)") do
--         dirStr = dirStr .. dir
--         MakeDir(dirStr)
--     end
--
-- On Windows this works because fullPath starts with a drive letter
-- ("C:/..."), which gmatch captures intact, so the accumulated dirStr
-- stays absolute throughout. On POSIX absolute paths ("/private/tmp/..."),
-- Lua's [^/]+ pattern requires one or more non-"/" chars, so the leading
-- "/" is SKIPPED and gmatch starts yielding from "private/" onward. The
-- accumulated dirStr is then RELATIVE ("private/tmp/...") and MakeDir
-- resolves it against cwd, creating a phantom directory tree under cwd
-- while the real absolute destination is never created. UpdateApply.lua
-- then spins forever in its io.open retry loop.
--
-- The minimal fix is to seed dirStr with "/" when fullPath starts with
-- "/". The per-segment loop is otherwise fine — it's the intentional
-- workaround for MakeDir being a single-directory primitive and it works
-- correctly on absolute paths once dirStr has the right prefix.
--
-- We apply the fix with a gsub that replaces the `local dirStr = ""`
-- initialization with a conditional form. The gsub is targeted enough
-- that it won't match anything else in UpdateCheck.lua, and a no-op if
-- upstream ever renames or restructures the loop.
local function patchUpdateCheckSource(text)
    if type(text) ~= "string" then return text end
    local patched = text:gsub(
        'local dirStr = ""',
        'local dirStr = data.fullPath:sub(1,1) == "/" and "/" or ""'
    )
    return patched
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

-- Wrap LoadModule so the first-run path ("first.run" marker at startup
-- triggers LoadModule("UpdateCheck") in Launch.lua:37) also gets the
-- MakeDir loop fix. Without this, fresh installs would hang on the first
-- update apply the same way the regular CheckForUpdate path would. We
-- read the file ourselves, gsub the broken loop, and compile via load()
-- so the patched text runs in place of the original. Everything else
-- delegates to the upstream LoadModule to avoid breaking other callers.
do
    local origLoadModule = LoadModule
    LoadModule = function(name, ...)
        if name == "UpdateCheck" then
            local fileName = name
            if not fileName:find("%.") then
                fileName = fileName .. ".lua"
            end
            local f = io.open(fileName, "r")
            if f then
                local text = f:read("*a")
                f:close()
                text = patchUpdateCheckSource(text)
                -- load() does not skip shebangs, so strip the leading "#@" line
                -- that upstream UpdateCheck.lua starts with.
                text = text:gsub("^#[^\n]*\n", "")
                local chunk, err = load(text, "@" .. fileName)
                if not chunk then
                    error("mac_entry.lua: load(UpdateCheck) failed: " .. tostring(err))
                end
                return chunk(...)
            end
        end
        return origLoadModule(name, ...)
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
            -- Fix the broken per-segment MakeDir loop. See file header.
            scriptText = patchUpdateCheckSource(scriptText)
            scriptText = subPreamble .. scriptText
        end
        return origLaunchSubScript(scriptText, funcList, subList, ...)
    end
end

-- Hand off to upstream Launch.lua. cwd at this point is src/ (set by the
-- launcher → sys_main → SetWorkDir from our entry script's path), so a
-- relative dofile resolves correctly.
dofile("Launch.lua")
