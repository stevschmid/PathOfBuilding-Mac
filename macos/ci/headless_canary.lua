-- Boot Path of Building headless on the assembled post-update tree and open
-- a build. Must run with cwd = the assembled src/ and LUA_PATH layered like
-- the launcher sets it (src/lua first, bundled runtime/lua fallback), with
-- stdin at /dev/null: on a startup error HeadlessWrapper prints the message,
-- reads stdin, and returns with exit code 0, so success has to be asserted
-- here rather than read off the exit status.
--
-- Opening a build matters: Build mode construction is what pulls in the tab
-- classes and their requires (the sha2 incident surfaced in ImportTab's
-- constructor, well after a clean-looking startup).

local function abort(phase, msg)
    print(string.format("headless_canary: %s FAILED:\n%s", phase, tostring(msg)))
    os.exit(1)
end

local function assertClean(phase)
    if launch and launch.promptMsg then
        abort(phase, launch.promptMsg)
    end
end

local ok, err = pcall(dofile, "HeadlessWrapper.lua")
if not ok then
    abort("startup", err)
end
assertClean("startup")
if not build then
    abort("startup", "aborted before BUILD mode was registered (no error prompt captured)")
end

ok, err = pcall(newBuild)
if not ok then
    abort("newBuild", err)
end
assertClean("newBuild")

print(string.format("headless_canary: OK (PoB version %s)", tostring(launch.versionNumber)))
