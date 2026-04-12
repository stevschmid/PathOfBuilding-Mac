// macOS launcher for SimpleGraphic / Path of Building
//
// Two operating modes:
//
//   1. Bundle mode (default when running as "Path of Building.app")
//      The executable lives at  Path of Building.app/Contents/MacOS/Path of Building
//      and PoB's Lua tree, fonts, and bundled Lua modules are in
//      Path of Building.app/Contents/Resources/{src,SimpleGraphic,lua}.
//      The launcher takes no arguments — it auto-discovers the script and
//      data paths from its own location.
//
//      On launch, the bundle's Contents/Resources/src tree is relocated
//      into ~/Library/Application Support/PathOfBuildingMac/src so that
//      (a) PoB's in-app updater has a user-writable destination for its
//      downloads, and (b) runtime writes never invalidate the bundle's
//      code signature. See RelocateRuntime() below.
//
//      In bundle mode the entry script is <AppSupport>/src/mac_entry.lua
//      (a thin bootstrap that installs the in-app updater's manifest
//      filter, then hands off to src/Launch.lua via dofile). If
//      mac_entry.lua isn't present, we fall back to src/Launch.lua
//      directly so a stripped-down bundle still launches.
//
//   2. Dev mode (running the binary directly with a script path argument)
//      argv[1] is a path to a Lua script, and the launcher derives the
//      PoB root from it. Used for iterating against an unbundled checkout.
//      Dev mode does NOT relocate into App Support.
//
// Mode is detected by checking whether <exeDir>/../Resources/src/Launch.lua
// exists. If yes → bundle, if no → dev.
//
// This file is C++ so that the relocation logic can lean on <filesystem>
// (create_directories, remove_all, copy, copy_file) instead of hand-rolling
// POSIX helpers. The main() plumbing (dlopen, _NSGetExecutablePath, env var
// setup, RunLuaFileAsWin invocation) stays C-style because it works fine
// and rewriting it to C++ idioms would be scope creep.

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <system_error>

#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef POB_BUNDLE_VERSION_STRING
#error "POB_BUNDLE_VERSION_STRING must be defined at compile time (set by CMake)"
#endif
#ifndef POB_APP_SUPPORT_DIR
#error "POB_APP_SUPPORT_DIR must be defined at compile time (set by CMake)"
#endif

namespace fs = std::filesystem;

typedef int (*RunLuaFileAsWin_t)(int argc, char** argv);

// Resolve ~/Library/Application Support/<POB_APP_SUPPORT_DIR>. Prefers
// $HOME, falls back to getpwuid(). Returns an empty path on failure.
static fs::path GetAppSupportDir()
{
    const char* home = std::getenv("HOME");
    if (!home || !home[0]) {
        struct passwd* pw = getpwuid(getuid());
        if (!pw || !pw->pw_dir) return {};
        home = pw->pw_dir;
    }
    return fs::path(home) / "Library/Application Support" / POB_APP_SUPPORT_DIR;
}

// Relocate the bundle's Contents/Resources/src tree into App Support so
// that all mutable runtime state (PoB's in-app updater writes, SG's
// SimpleGraphic.cfg, Dear ImGui's imgui.ini) lives in a user-writable
// location that will not invalidate the signed bundle's sealed manifest.
//
// Strategy:
//   1. If the marker file matches POB_BUNDLE_VERSION_STRING, the extracted
//      tree is up-to-date for this DMG — leave it alone. Preserves in-app
//      updater state across launches.
//   2. Otherwise remove App Support/src and re-populate from bundleSrc.
//      This handles first launch (marker missing) and DMG bumps (marker
//      stale). In-app updater changes from a previous DMG are intentionally
//      discarded — a new DMG is a "reset to this baseline" operation.
//   3. Always overwrite mac_entry.lua from the bundle afterwards. It's our
//      wrapper bootstrap, never touched by PoB's updater, and we want dev
//      iteration on this file to take effect without requiring a
//      POB_BUNDLE_VERSION bump or manual marker deletion.
//
// Returns the App Support root on success, nullopt on failure. On failure
// callers should bail — running out of the bundle would invalidate its
// signature and fail on /Applications (not user-writable).
static std::optional<fs::path> RelocateRuntime(const fs::path& bundleSrc)
{
    std::error_code ec;

    fs::path root = GetAppSupportDir();
    if (root.empty()) {
        std::fprintf(stderr, "RelocateRuntime: cannot determine home directory\n");
        return std::nullopt;
    }
    fs::create_directories(root, ec);
    if (ec) {
        std::fprintf(stderr, "RelocateRuntime: mkdir %s failed: %s\n",
            root.c_str(), ec.message().c_str());
        return std::nullopt;
    }

    const fs::path appSrc     = root / "src";
    const fs::path markerPath = root / ".bundle_version";
    const std::string wanted  = POB_BUNDLE_VERSION_STRING;

    // Read the current marker (if any), trimming trailing whitespace so
    // comparison is stable regardless of how the file was written.
    std::string current;
    {
        std::ifstream f(markerPath);
        if (f) std::getline(f, current);
        while (!current.empty()
               && std::isspace(static_cast<unsigned char>(current.back()))) {
            current.pop_back();
        }
    }

    const bool needRefresh = !fs::exists(appSrc) || current != wanted;

    if (needRefresh) {
        if (!current.empty()) {
            std::fprintf(stderr,
                "RelocateRuntime: bundle version changed (marker=%s, bundle=%s), refreshing %s\n",
                current.c_str(), wanted.c_str(), appSrc.c_str());
        }

        fs::remove_all(appSrc, ec);
        if (ec) {
            std::fprintf(stderr, "RelocateRuntime: remove_all %s failed: %s\n",
                appSrc.c_str(), ec.message().c_str());
            return std::nullopt;
        }

        // fs::copy with copy_options::recursive creates `appSrc` as an
        // empty directory and then recursively copies `bundleSrc`'s
        // entries into it. `appSrc`'s parent (`root`) already exists from
        // create_directories above.
        fs::copy(bundleSrc, appSrc, fs::copy_options::recursive, ec);
        if (ec) {
            std::fprintf(stderr, "RelocateRuntime: copy %s -> %s failed: %s\n",
                bundleSrc.c_str(), appSrc.c_str(), ec.message().c_str());
            return std::nullopt;
        }

        std::ofstream f(markerPath);
        if (!f) {
            std::fprintf(stderr, "RelocateRuntime: write marker %s failed\n",
                markerPath.c_str());
            return std::nullopt;
        }
        f << wanted << '\n';
    }

    // Always refresh mac_entry.lua from the bundle. It's our file, the
    // updater never touches it, and keeping it always-fresh lets dev
    // iteration take effect without a POB_BUNDLE_VERSION bump.
    const fs::path entrySrc = bundleSrc / "mac_entry.lua";
    const fs::path entryDst = appSrc   / "mac_entry.lua";
    if (fs::exists(entrySrc)) {
        fs::remove(entryDst, ec);  // ignore ENOENT
        fs::copy_file(entrySrc, entryDst,
            fs::copy_options::overwrite_existing, ec);
        if (ec) {
            // Non-fatal: the extracted tree already has a mac_entry.lua
            // from the refresh branch above, just potentially stale.
            std::fprintf(stderr, "RelocateRuntime: refresh mac_entry.lua failed: %s\n",
                ec.message().c_str());
        }
    }

    return root;
}

int main(int argc, char** argv)
{
    // ----- Resolve our own executable's directory -----
    // _NSGetExecutablePath gives us a path that may not be canonical
    // (can contain symlinks or relative components), so realpath it.
    char rawExePath[PATH_MAX];
    uint32_t rawExePathSize = sizeof(rawExePath);
    if (_NSGetExecutablePath(rawExePath, &rawExePathSize) != 0) {
        std::fprintf(stderr, "_NSGetExecutablePath: buffer too small (%u)\n", rawExePathSize);
        return 1;
    }

    char exePath[PATH_MAX];
    if (realpath(rawExePath, exePath) == NULL) {
        perror("realpath(exePath)");
        return 1;
    }

    // POSIX dirname() may return a pointer to static storage that subsequent
    // dirname() calls will overwrite (and macOS does exactly this). Always
    // copy the result into an owned buffer immediately.
    char exeDirSrc[PATH_MAX];
    strncpy(exeDirSrc, exePath, sizeof(exeDirSrc));
    char dir[PATH_MAX];
    strncpy(dir, dirname(exeDirSrc), sizeof(dir));
    dir[sizeof(dir) - 1] = '\0';

    // ----- Pre-load ANGLE GLES + EGL from our own directory -----
    // GLFW's EGL backend later does dlopen("libEGL.dylib", ...) by leaf name,
    // which dyld will satisfy from the already-loaded image table once we've
    // loaded these by absolute path. (dyld does NOT search LC_RPATH or
    // @loader_path for bare-name dlopen() calls, so this is the cleanest way
    // to make GLFW find ANGLE without polluting DYLD_LIBRARY_PATH.)
    char libGLESPath[PATH_MAX];
    std::snprintf(libGLESPath, sizeof(libGLESPath), "%s/libGLESv2.dylib", dir);
    if (!dlopen(libGLESPath, RTLD_LAZY | RTLD_GLOBAL)) {
        std::fprintf(stderr, "Failed to pre-load %s: %s\n", libGLESPath, dlerror());
        return 1;
    }

    char libEGLPath[PATH_MAX];
    std::snprintf(libEGLPath, sizeof(libEGLPath), "%s/libEGL.dylib", dir);
    if (!dlopen(libEGLPath, RTLD_LAZY | RTLD_GLOBAL)) {
        std::fprintf(stderr, "Failed to pre-load %s: %s\n", libEGLPath, dlerror());
        return 1;
    }

    // ----- Load libSimpleGraphic.dylib from the same directory -----
    char libPath[PATH_MAX];
    std::snprintf(libPath, sizeof(libPath), "%s/libSimpleGraphic.dylib", dir);

    void* lib = dlopen(libPath, RTLD_LAZY | RTLD_GLOBAL);
    if (!lib) {
        std::fprintf(stderr, "Failed to load %s: %s\n", libPath, dlerror());
        return 1;
    }

    RunLuaFileAsWin_t runLua = (RunLuaFileAsWin_t)dlsym(lib, "RunLuaFileAsWin");
    if (!runLua) {
        std::fprintf(stderr, "dlsym RunLuaFileAsWin: %s\n", dlerror());
        return 1;
    }

    // ----- Detect bundle vs dev mode -----
    // Bundle layout: <exeDir>/../Resources/src/Launch.lua
    char bundleResources[PATH_MAX];
    std::snprintf(bundleResources, sizeof(bundleResources), "%s/../Resources", dir);
    char bundleResourcesAbs[PATH_MAX];
    if (!realpath(bundleResources, bundleResourcesAbs))
        bundleResourcesAbs[0] = '\0';

    const fs::path bundleResourcesPath = bundleResourcesAbs;
    const fs::path bundleSrcPath       = bundleResourcesPath / "src";
    const fs::path bundleLaunchPath    = bundleSrcPath / "Launch.lua";

    const bool bundleMode = (bundleResourcesAbs[0] != '\0')
                         && fs::exists(bundleLaunchPath);

    char scriptAbs[PATH_MAX];
    char sgBasePath[PATH_MAX];
    char luaPath[PATH_MAX * 4];
    char luaCPath[PATH_MAX * 4];

    if (bundleMode) {
        // Relocate src/ into ~/Library/Application Support/PathOfBuildingMac
        // so the in-app updater, SimpleGraphic.cfg, and imgui.ini all have
        // a user-writable destination that won't tamper with the signed
        // bundle.
        const auto appSupport = RelocateRuntime(bundleSrcPath);
        if (!appSupport) {
            std::fprintf(stderr,
                "fatal: could not relocate runtime tree to Application Support\n");
            return 1;
        }

        // Publish the App Support root to SimpleGraphic so it can redirect
        // its own cfg files and imgui.ini away from basePath.
        setenv("POB_MAC_USER_DIR", appSupport->c_str(), 1);

        const fs::path appSrcPath = *appSupport / "src";

        // Prefer mac_entry.lua (the bootstrap that patches the in-app
        // updater); fall back to Launch.lua if somehow absent.
        const fs::path entryCandidate = appSrcPath / "mac_entry.lua";
        const fs::path scriptPath = fs::exists(entryCandidate)
            ? entryCandidate
            : appSrcPath / "Launch.lua";
        strncpy(scriptAbs, scriptPath.c_str(), sizeof(scriptAbs));
        scriptAbs[sizeof(scriptAbs) - 1] = '\0';

        // SG_BASE_PATH keeps pointing at the bundle's Contents/Resources —
        // fonts and runtime/lua are read-only and don't need to move.
        strncpy(sgBasePath, bundleResourcesAbs, sizeof(sgBasePath));
        sgBasePath[sizeof(sgBasePath) - 1] = '\0';

        std::snprintf(luaPath, sizeof(luaPath),
            "%s/lua/?.lua;%s/lua/?/init.lua;;",
            bundleResourcesAbs, bundleResourcesAbs);
    } else {
        // Dev: argv[1] is the Lua script path, derive everything from it.
        if (argc < 2) {
            std::fprintf(stderr,
                "Usage: %s <script.lua> [args...]\n"
                "(Or run as a Path of Building.app bundle.)\n",
                argv[0]);
            return 1;
        }

        if (realpath(argv[1], scriptAbs) == NULL) {
            perror(argv[1]);
            return 1;
        }

        char scriptDirBuf[PATH_MAX];
        strncpy(scriptDirBuf, scriptAbs, sizeof(scriptDirBuf));
        char scriptDir[PATH_MAX];
        strncpy(scriptDir, dirname(scriptDirBuf), sizeof(scriptDir));
        scriptDir[sizeof(scriptDir) - 1] = '\0';

        char pobRoot[PATH_MAX];
        std::snprintf(pobRoot, sizeof(pobRoot), "%s/..", scriptDir);
        char pobRootAbs[PATH_MAX];
        if (!realpath(pobRoot, pobRootAbs))
            strncpy(pobRootAbs, pobRoot, sizeof(pobRootAbs));

        // SG_BASE_PATH on dev: the launcher's own dir (where we install
        // SimpleGraphic/Fonts/ alongside the binary).
        strncpy(sgBasePath, dir, sizeof(sgBasePath));
        sgBasePath[sizeof(sgBasePath) - 1] = '\0';

        std::snprintf(luaPath, sizeof(luaPath),
            "%s/runtime/lua/?.lua;%s/runtime/lua/?/init.lua;;",
            pobRootAbs, pobRootAbs);
    }

    // LUA_CPATH always points at the launcher dir — both modes have the
    // Lua C modules sitting next to the binary.
    std::snprintf(luaCPath, sizeof(luaCPath), "%s/?.dylib;;", dir);

    // ----- Push env vars and hand off to SimpleGraphic -----
    if (!getenv("SG_BASE_PATH"))
        setenv("SG_BASE_PATH", sgBasePath, 1);

    // Work around pob-wide-crt.patch: _lua_getenvcopy() calls
    // strdup(getenv(name)) which crashes on NULL, so we always set these
    // even if we're not overriding.
    if (!getenv("LUA_PATH"))
        setenv("LUA_PATH", luaPath, 1);
    if (!getenv("LUA_CPATH"))
        setenv("LUA_CPATH", luaCPath, 1);

    // Build the argv vector handed to RunLuaFileAsWin: argv[0] must be
    // the Lua script path, followed by any extra script arguments.
    if (bundleMode) {
        char* runArgv[] = { scriptAbs, NULL };
        return runLua(1, runArgv);
    } else {
        argv[1] = scriptAbs;
        return runLua(argc - 1, argv + 1);
    }
}
