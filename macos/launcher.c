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
//      In bundle mode the entry script is src/mac_entry.lua (a thin
//      bootstrap that installs the in-app updater's manifest filter, then
//      hands off to src/Launch.lua via dofile). If mac_entry.lua isn't
//      present, we fall back to src/Launch.lua directly so a stripped-down
//      bundle still launches.
//
//   2. Dev mode (running the binary directly with a script path argument)
//      Same shape as PR #98's linux/launcher.c: argv[1] is a path to a
//      Lua script, and the launcher derives the PoB root from it. Used for
//      iterating against an unbundled checkout of the PoB main repo.
//
// Mode is detected by checking whether <exeDir>/../Resources/src/Launch.lua
// exists. If yes → bundle, if no → dev.

#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int (*RunLuaFileAsWin_t)(int argc, char** argv);

static int file_exists(const char* path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

int main(int argc, char** argv)
{
    // ----- Resolve our own executable's directory -----
    // _NSGetExecutablePath gives us a path that may not be canonical
    // (can contain symlinks or relative components), so realpath it.
    char rawExePath[PATH_MAX];
    uint32_t rawExePathSize = sizeof(rawExePath);
    if (_NSGetExecutablePath(rawExePath, &rawExePathSize) != 0) {
        fprintf(stderr, "_NSGetExecutablePath: buffer too small (%u)\n", rawExePathSize);
        return 1;
    }

    char exePath[PATH_MAX];
    if (realpath(rawExePath, exePath) == NULL) {
        perror("realpath(exePath)");
        return 1;
    }

    // POSIX dirname() may return a pointer to static storage that subsequent
    // dirname() calls will overwrite (and macOS does exactly this). Always
    // copy the result into an owned buffer immediately, before any further
    // dirname() call clobbers it.
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
    snprintf(libGLESPath, sizeof(libGLESPath), "%s/libGLESv2.dylib", dir);
    if (!dlopen(libGLESPath, RTLD_LAZY | RTLD_GLOBAL)) {
        fprintf(stderr, "Failed to pre-load %s: %s\n", libGLESPath, dlerror());
        return 1;
    }

    char libEGLPath[PATH_MAX];
    snprintf(libEGLPath, sizeof(libEGLPath), "%s/libEGL.dylib", dir);
    if (!dlopen(libEGLPath, RTLD_LAZY | RTLD_GLOBAL)) {
        fprintf(stderr, "Failed to pre-load %s: %s\n", libEGLPath, dlerror());
        return 1;
    }

    // ----- Load libSimpleGraphic.dylib from the same directory -----
    char libPath[PATH_MAX];
    snprintf(libPath, sizeof(libPath), "%s/libSimpleGraphic.dylib", dir);

    void* lib = dlopen(libPath, RTLD_LAZY | RTLD_GLOBAL);
    if (!lib) {
        fprintf(stderr, "Failed to load %s: %s\n", libPath, dlerror());
        return 1;
    }

    RunLuaFileAsWin_t runLua = (RunLuaFileAsWin_t)dlsym(lib, "RunLuaFileAsWin");
    if (!runLua) {
        fprintf(stderr, "dlsym RunLuaFileAsWin: %s\n", dlerror());
        return 1;
    }

    // ----- Detect bundle vs dev mode -----
    // Bundle layout:
    //   <exeDir>/../Resources/src/Launch.lua
    char bundleResources[PATH_MAX];
    snprintf(bundleResources, sizeof(bundleResources), "%s/../Resources", dir);
    char bundleResourcesAbs[PATH_MAX];
    if (!realpath(bundleResources, bundleResourcesAbs))
        bundleResourcesAbs[0] = '\0';

    char bundleLaunch[PATH_MAX];
    snprintf(bundleLaunch, sizeof(bundleLaunch), "%s/src/Launch.lua", bundleResourcesAbs);

    // Prefer the macOS bootstrap entry (which patches the in-app updater
    // before handing off to Launch.lua); fall back to Launch.lua directly
    // if the bootstrap is missing.
    char bundleEntry[PATH_MAX];
    snprintf(bundleEntry, sizeof(bundleEntry), "%s/src/mac_entry.lua", bundleResourcesAbs);
    if (!file_exists(bundleEntry)) {
        strncpy(bundleEntry, bundleLaunch, sizeof(bundleEntry));
        bundleEntry[sizeof(bundleEntry) - 1] = '\0';
    }

    int bundleMode = (bundleResourcesAbs[0] != '\0') && file_exists(bundleLaunch);

    // ----- Compute the script path, base path, and Lua paths -----
    char scriptAbs[PATH_MAX];
    char sgBasePath[PATH_MAX];
    char luaPath[PATH_MAX * 4];
    char luaCPath[PATH_MAX * 4];

    if (bundleMode) {
        // Bundle: ignore argv entirely, use the bundled tree.
        strncpy(scriptAbs, bundleEntry, sizeof(scriptAbs));
        scriptAbs[sizeof(scriptAbs) - 1] = '\0';

        strncpy(sgBasePath, bundleResourcesAbs, sizeof(sgBasePath));
        sgBasePath[sizeof(sgBasePath) - 1] = '\0';

        snprintf(luaPath, sizeof(luaPath),
            "%s/lua/?.lua;%s/lua/?/init.lua;;",
            bundleResourcesAbs, bundleResourcesAbs);
    } else {
        // Dev: argv[1] is the Lua script path, derive everything from it.
        if (argc < 2) {
            fprintf(stderr,
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
        snprintf(pobRoot, sizeof(pobRoot), "%s/..", scriptDir);
        char pobRootAbs[PATH_MAX];
        if (!realpath(pobRoot, pobRootAbs))
            strncpy(pobRootAbs, pobRoot, sizeof(pobRootAbs));

        // SG_BASE_PATH on dev: the launcher's own dir (where we install
        // SimpleGraphic/Fonts/ alongside the binary).
        strncpy(sgBasePath, dir, sizeof(sgBasePath));
        sgBasePath[sizeof(sgBasePath) - 1] = '\0';

        snprintf(luaPath, sizeof(luaPath),
            "%s/runtime/lua/?.lua;%s/runtime/lua/?/init.lua;;",
            pobRootAbs, pobRootAbs);
    }

    // LUA_CPATH always points at the launcher dir — both modes have the
    // Lua C modules sitting next to the binary.
    snprintf(luaCPath, sizeof(luaCPath), "%s/?.dylib;;", dir);

    // ----- Push env vars and hand off to SimpleGraphic -----
    // Tell SimpleGraphic where the runtime data (fonts, etc.) lives.
    if (!getenv("SG_BASE_PATH"))
        setenv("SG_BASE_PATH", sgBasePath, 1);

    // Work around pob-wide-crt.patch: _lua_getenvcopy() calls strdup(getenv(name))
    // which crashes on NULL, so we always set these even if we're not overriding.
    if (!getenv("LUA_PATH"))
        setenv("LUA_PATH", luaPath, 1);
    if (!getenv("LUA_CPATH"))
        setenv("LUA_CPATH", luaCPath, 1);

    // Build the argv vector handed to RunLuaFileAsWin: argv[0] must be the
    // Lua script path, followed by any extra script arguments.
    if (bundleMode) {
        // No script args from the user — just hand over the script path.
        char* runArgv[] = { scriptAbs, NULL };
        return runLua(1, runArgv);
    } else {
        argv[1] = scriptAbs;
        return runLua(argc - 1, argv + 1);
    }
}
