# Notes for upstream PRs

Things discovered during the macOS port that should be sent back upstream once stabilized.

## luajit version bump: PR #98's pin is missing critical Apple Silicon JIT fix

**Files:**
- `vcpkg-ports/ports/luajit/2026-03-30_0/` (renamed from `2025-07-24_1/`)
- `vcpkg-ports/versions/l-/luajit.json`
- `vcpkg-ports/versions/baseline.json`

**Bug:** PR #98 pinned LuaJIT to commit `871db2c84ecefd70a850e03a6c340214a81739f0` (2025-07-24). On Apple Silicon arm64, this commit has a fundamental issue: **the JIT compiler can't allocate executable memory.**

LuaJIT's mcode allocator (`src/lj_mcode.c`) needs to place machine code within ±127MB of the `lj_vm_exit_handler` symbol so the arm64 BL/B branch instructions (which encode a ±128MB signed offset) can reach support code. To find a free page in that window, the allocator does up to 27 `mmap()` attempts with placement hints around the target address. **On Apple Silicon, MAP_JIT mmap doesn't honor placement hints** — the kernel allocates JIT pages in its own special region, far from any specific hint. So all 27 attempts fail to land in range, the trace bails with `LJ_TRERR_MCODEAL` (errno 27), and PoB falls back to the interpreter for *every* hot loop. Result: a single passive-tree node click takes ~1.5 seconds instead of <50 ms because the entire stat-recompute pipeline runs interpreted.

We diagnosed this with a `jit.attach` probe in PoB's Launch.lua that recorded trace event counts and abort reasons. The histogram on a single slow frame showed:

| oex | LuaJIT name | count | % |
|---|---|---|---|
| 27 | failed to allocate mcode memory | 187,500 | ~75% |
| 8 | leaving loop in root trace | 39,794 | ~16% |
| 9 | inner loop in root trace | 21,952 | ~9% |
| 7 | NYI bytecode | 1,051 | <1% |

Cumulative `stop` count was **0** for the entire run — not a single trace ever successfully compiled. This is a known LuaJIT issue tracked as [LuaJIT/LuaJIT#285](https://github.com/LuaJIT/LuaJIT/issues/285) (with #1280 closed as duplicate). It affects any project that statically links LuaJIT into a `dlopen()`'d shared library on Apple Silicon, and there were comments from multiple affected developers (Minetest devs, game engines, etc.) reporting the same symptom.

**Fix:** Mike Pall implemented a "general solution" on **2025-11-05** in commit [`68354f4447`](https://github.com/LuaJIT/LuaJIT/commit/68354f4447) — *"Allow mcode allocations outside of the jump range to the support code"* — which uses trampoline indirection when an in-range mcode page can't be obtained. PR #98's pinned LuaJIT commit predates this fix by ~3.5 months.

We bumped the overlay port to LuaJIT commit `18b087cd2cd4ddc4a79782bf155383a689d5093d` (2026-03-30, current `v2.1` branch head) which contains the trampoline fix plus ~200 other upstream improvements from the intervening 8 months. Click latency went from ~1.5s to instant.

**Cross-platform impact:** PR #98 also adds `-DLUAJIT_ENABLE_GC64` on Linux as a workaround for a *related but distinct* issue (LuaJIT statically linked into a `dlopen()`'d `.so` failing GC allocation when its code section is loaded above 4 GB virtual address). That GC64 workaround is independent of Mike Pall's mcode fix — but anyone hitting one of these issues should consider whether the LuaJIT bump alone now suffices for both.

**Side cleanup we did at the same time:**
- Renamed port directory `2025-07-24_1` → `2026-03-30_0` to match the new version-date.
- Pruned `vcpkg-ports/versions/l-/luajit.json` of port-versions 1–7 from PR #98 + our investigation experiments. Single new entry `2026-03-30 #0` replaces them.
- Made `msvcbuild.patch` (a Windows MSVC `.bat` patch from PR #98 with PDB/LTCG improvements) conditional on `VCPKG_TARGET_IS_WINDOWS` via the existing `extra_patches` if/list pattern. The patch's @@ line numbers shifted in the new LuaJIT commit and would have needed regenerating; gating it Windows-only sidesteps the fragility entirely (the patch only modifies a `.bat` file that no other platform builds).

**Scope:** this is the single most impactful fix we found. **It belongs upstream in PR #98 itself** as a version bump — both because PR #98 pinned an older LuaJIT and because PR #98's `LUAJIT_ENABLE_GC64` workaround is in the same family of fixes. The diff is small (commit hash + SHA512 + the rename + the conditional patch reorganization). No code changes to anything in `engine/`, `ui_*.cpp`, or anywhere else in SimpleGraphic.

## luajit portfile: hardcoded `x64-linux-rel`/`x64-linux-dbg` build subdir

**File:** `vcpkg-ports/ports/luajit/2026-03-30_0/portfile.cmake` (lines ~104–119)

**Bug:** PR #98's symlink fix (the `foreach(BUILDTYPE ...)` block that replaces the broken circular `bin/luajit -> luajit` symlink with the real binary from the build tree) hardcodes the build directory name to `x64-linux-rel` and `x64-linux-dbg`. On any other triplet (e.g. `arm64-osx`) the `EXISTS "${REAL_BIN}"` check is false, the `file(COPY)` never runs, and `vcpkg_copy_tools(TOOL_NAMES luajit ...)` then fails because `bin/luajit` is still the broken symlink the install step left behind:

```
CMake Error at scripts/cmake/vcpkg_copy_tools.cmake:32 (message):
  Couldn't find tool "luajit":
      neither ".../bin/luajit" nor ".../bin/luajit.app" exists
```

**Fix:** use the `TARGET_TRIPLET` variable that vcpkg already provides in port context:

```cmake
set(BUILD_SUBDIR "${TARGET_TRIPLET}-rel")  # was: "x64-linux-rel"
set(BUILD_SUBDIR "${TARGET_TRIPLET}-dbg")  # was: "x64-linux-dbg"
```

This is generic — it fixes Linux too (any non-x64-linux Linux triplet would have hit the same issue) and unlocks macOS/etc.

**Scope:** the fix is small and platform-agnostic. Worth either folding into PR #98 directly or sending as a follow-up PR after #98 lands.

**Port-version:** locally bumped 3 → 4 (in `vcpkg.json`, `versions/l-/luajit.json`, `versions/baseline.json`) to force vcpkg to pick up the change. Upstream PR doesn't need a new port-version bump if it amends PR #98 before merge.

## lcurl `luaL_setfuncs` duplicate symbol — replace GNU-ld flag with per-source rename

**File:** `CMakeLists.txt` (lcurl section)

**Bug:** PR #98 worked around the `luaL_setfuncs` duplicate-symbol collision (LuaJIT 2.1 exports it via its 5.2 compat layer; Lua-cURLv3's `l52util.c` also defines it under its `LUA_VERSION_NUM < 502` branch because LuaJIT reports `LUA_VERSION_NUM == 501`) by passing `-Wl,--allow-multiple-definition` to lcurl's link, gated `if (NOT WIN32)`. That flag is **GNU ld–only**; ld64 (Apple) rejects it as `unknown options: --allow-multiple-definition` and the link fails outright on macOS. (mold and lld both accept it; MSVC link.exe doesn't see the collision in the first place because of how LuaJIT's headers handle import/export visibility on Windows.)

**Fix:** rename `l52util.c`'s local `luaL_setfuncs` definition out of the way at compile time using a per-source preprocessor define. CMake's `set_source_files_properties(... COMPILE_DEFINITIONS ...)` lets us scope the macro to one translation unit:

```cmake
if (NOT WIN32)
    set_source_files_properties(${LCURL_SOURCE_DIR}/src/l52util.c PROPERTIES
        COMPILE_DEFINITIONS "luaL_setfuncs=lcurl_unused_luaL_setfuncs")
endif()
```

This rewrites every occurrence of the identifier `luaL_setfuncs` in `l52util.c` (and only in that file) to `lcurl_unused_luaL_setfuncs`. Effects:

1. The local function definition becomes `void lcurl_unused_luaL_setfuncs(...)` — different symbol name, no collision.
2. The one internal call inside `lutil_createmetap` (also in `l52util.c`) calls the renamed local function. Since the renamed function is the original polyfill verbatim, behavior is identical.
3. Every other `.c` file in `Lua-cURLv3/src/` compiles unchanged. Their calls to `luaL_setfuncs` link to LuaJIT's real symbol normally.
4. The renamed function ends up as dead code that the linker may strip.

The submodule worktree is **never** modified — no patch file, no in-place edit, no `.gitmodules` config.

Verified via `nm -gU libluajit-5.1.a` that `luaL_setfuncs` is the *only* symbol that actually collides — `lua_rawgetp`, `lua_rawsetp`, `lua_absindex` are NOT exported by LuaJIT 2.1 and still need the polyfills, so the rename is narrowly targeted to just the one offending function.

With this in place, the `target_link_options(lcurl PRIVATE "-Wl,--allow-multiple-definition")` block in CMakeLists.txt is removed.

**Scope:** ~4 lines of CMake (gated `NOT WIN32`), no patch file, no submodule pollution. Cleaner than PR #98's GNU-ld workaround AND fixes macOS at the same time. Folds naturally into PR #98 as a one-line replacement of the existing `target_link_options` block.

## CMakeLists.txt: `SIMPLEGRAPHIC_PLATFORM_SOURCES` clobbered on Apple

**File:** `CMakeLists.txt` (~lines 79–95)

**Bug:** pre-existing, not introduced by PR #98. The block reads:

```cmake
set (SIMPLEGRAPHIC_PLATFORM_SOURCES)
if (APPLE)
    set (SIMPLEGRAPHIC_PLATFORM_SOURCES "engine/system/win/sys_macos.mm")
endif()

if (WIN32)
    set (SIMPLEGRAPHIC_PLATFORM_SOURCES "engine/system/win/sys_console.cpp" "SimpleGraphic.rc")
else()
    set (SIMPLEGRAPHIC_PLATFORM_SOURCES "engine/system/win/sys_console_unix.cpp")
endif()
```

On macOS the first block sets `sys_macos.mm`, then the second block's `else()` branch fires (because `APPLE && !WIN32`) and **`set()`s it again**, overwriting the earlier value with just `sys_console_unix.cpp`. Net result on macOS: `sys_macos.mm` is silently dropped, `PlatformOpenURL` (its only function) is never compiled, and `libSimpleGraphic.dylib` fails to link. The `if(APPLE)` block was apparently never actually exercised by whoever added it.

**Fix:** change both `set()` calls in the conditional branches to `list(APPEND ...)` so the contributions stack instead of clobber. The leading `set(SIMPLEGRAPHIC_PLATFORM_SOURCES)` already initializes the variable to empty, which is exactly what `list(APPEND)` needs.

**Scope:** small, platform-agnostic correctness fix. Folds naturally into PR #98 (since #98 didn't touch this block but it's part of the same general "make non-Windows builds work" theme), or as a tiny standalone PR.

## r_font.cpp: text visibility cull uses logical window size, not framebuffer size

**File:** `engine/render/r_font.cpp` (line ~325, `r_font_c::DrawTextLine`)

**Bug:** the per-line "is this even visible?" early-out reads:

```cpp
if (pos[Y] >= renderer->sys->video->vid.size[1] || pos[Y] <= -height) {
    // process color codes only, then return without drawing
}
```

`pos[Y]` is in the same coordinate space as `VirtualScreenWidth/Height()`, which in `apiDpiAware` mode returns `vid.fbSize` (physical framebuffer pixels). But the comparison upper bound is `vid.size[1]` — the **logical** window height. On any HiDPI display where `vid.size[1] != vid.fbSize[1]` (macOS Retina, HiDPI Wayland, fractional Windows DPI scales), this is half (or some fraction) of the framebuffer height. Every text draw whose `pos[Y]` lands in the bottom half of the screen short-circuits to the no-draw path silently. Checkboxes and other geometry drawn through `r_layer_c::Quad` still appear because they use the correct `VirtualScreenWidth()` cull a few lines down (line ~384), so the symptom is "rectangles fine, labels missing in the lower half of the screen / inside any popup positioned there / inside hover tooltips".

**Fix:** use `renderer->VirtualScreenHeight()` for the upper-bound check, matching the coordinate space of `pos[Y]` and the existing X-axis cull at line 384:

```cpp
if (pos[Y] >= renderer->VirtualScreenHeight() || pos[Y] <= -height) {
```

**Scope:** one-line fix, platform-agnostic, fixes a serious-looking visual bug on every HiDPI display (Linux Wayland users with fractional scaling are likely affected too — they just may not have noticed because Linux PoB usage is rare). High upstream value.

## sys_video.cpp: cursor coordinates on macOS are in logical points, not pixels

**File:** `engine/system/win/sys_video.cpp` (`sys_video_c::GetRelativeCursor`)

**Bug:** GLFW's `glfwGetCursorPos` returns logical "screen coordinates" (points) on macOS Cocoa but physical pixels on Win32 (because Win32's `GetCursorPos` is in pixels under per-monitor-DPI-aware-V2, which GLFW enables). The rest of the engine assumes physical pixels — `vid.fbSize` is in pixels, `VirtualScreenWidth/Height()` returns pixels in `apiDpiAware` mode, the Lua `GetCursorPos` binding does `VirtualMap(cursorX) / dpiScale` on the assumption that `cursorX` is already in pixels. On macOS Retina the cursor reports at half (or a fraction) of its visible position, so hit-testing is offset by exactly the DPI scale factor.

**Fix:** normalize at the source — multiply the GLFW cursor position by `vid.dpiScale` on Apple so the rest of the engine sees a consistent coordinate system:

```cpp
glfwGetCursorPos(wnd, &xpos, &ypos);
#ifdef __APPLE__
    xpos *= vid.dpiScale;
    ypos *= vid.dpiScale;
#endif
```

**Scope:** Apple-only #ifdef around a one-line scaling. The proper long-term fix is probably to normalize the engine's internal coordinate space and stop mixing logical/physical anywhere — but this `#ifdef` is the minimal change that unblocks macOS without touching Windows. Worth proposing alongside the r_font.cpp fix as part of a "HiDPI cleanup" mini-series.

## launcher (Linux + macOS): `dirname()` may return static storage, second call clobbers first

**Files:** `linux/launcher.c`, `macos/launcher.c`

**Bug:** POSIX `dirname(3)` is allowed to return either a pointer to a modified version of the input or a pointer to a **static buffer that subsequent `dirname()` calls will overwrite**. macOS libc takes the static-buffer path. The original `linux/launcher.c` from PR #98 calls `dirname()` twice (once on the launcher exe path, once on the script path) and stores both return values as `char*` aliases — on macOS, the second call silently rewrites the first call's value, so `setenv("SG_BASE_PATH", dir, 1)` ends up writing the script directory instead of the launcher directory. The downstream effect is that `FindBasePath()` returns the wrong directory and the engine can't find its data files (fonts, etc.).

The Linux launcher dodges this only because glibc's `dirname()` happens to modify in place and never returns static storage. POSIX permits both behaviors; relying on glibc's specific implementation is technically a latent bug there too.

**Fix:** copy each `dirname()` return into an owned buffer immediately:

```c
char dir[PATH_MAX];
strncpy(dir, dirname(exeDirSrc), sizeof(dir));
dir[sizeof(dir) - 1] = '\0';
```

**Scope:** the macOS launcher (`macos/launcher.c`) we're adding will have this baked in from the start. The Linux launcher in PR #98 should also be patched to use the same pattern — defends against any future libc change and matches POSIX intent.

## CMakeLists: `$<TARGET_RUNTIME_DLLS:>` is effectively Windows-only on macOS

**File:** `CMakeLists.txt` (install rules around `SimpleGraphic`)

**Bug:** the install rule uses `install(FILES $<TARGET_RUNTIME_DLLS:SimpleGraphic> DESTINATION ".")` to copy all transitively-linked shared libraries next to the launcher. On Windows this captures every `.dll` from imported targets in the link closure. On macOS the generator expression evaluates to **empty** despite imported targets being correctly defined as `SHARED IMPORTED` with valid `IMPORTED_LOCATION_RELEASE` paths. The result: when a vcpkg dep ships a `.dylib` (e.g. our `angle` overlay built dynamically), the install step silently leaves it behind.

**Fix:** for Apple, supplement with `install(IMPORTED_RUNTIME_ARTIFACTS ...)` listing each imported target whose runtime side needs to ship. CMake 3.21+:

```cmake
if (APPLE)
    install(IMPORTED_RUNTIME_ARTIFACTS
        unofficial::angle::libEGL
        unofficial::angle::libGLESv2
        LIBRARY DESTINATION "."
        RUNTIME DESTINATION "."
    )
endif()
```

**Scope:** affects any non-Windows build that links a shared imported target from vcpkg. On Linux, PR #98 sidesteps this by linking everything statically (`VCPKG_LIBRARY_LINKAGE static` is the default for `arm64-osx`/`x64-linux`). The macOS port hits it because we *have* to build ANGLE shared (GLFW's EGL backend `dlopen`s `libEGL.dylib` by leaf name and won't find symbols statically linked into our own dylib). Worth noting in PR #98 as a known limitation, or fixing if anyone wants shared-linkage Linux builds.

## ANGLE port (overlay): `liblibEGL.dylib` from double `lib` prefix when built shared on macOS

**File:** `vcpkg-ports/ports/angle/cmake-buildsystem/CMakeLists.txt` (around the `OUTPUT_NAME` set on the `EGL` and `GLESv2` targets)

**Bug:** the overlay angle CMakeLists already has a Windows path that sets `OUTPUT_NAME libGLESv2` / `libEGL` (full leading `lib`). For non-Windows it has a single fallback that sets `OUTPUT_NAME libGLESv2_angle` / `libEGL_angle` to avoid colliding with system OpenGL on Linux. CMake on macOS adds an automatic `lib` prefix to shared libraries (unlike Windows DLLs), so when angle is built as a `.dylib`, the auto prefix stacks with the leading `lib` in OUTPUT_NAME and you get `liblibEGL_angle.dylib`, `liblibGLESv2_angle.dylib`. Plus, on macOS there's no system `libEGL.dylib` to collide with anyway, so the `_angle` suffix is both unnecessary *and* breaks GLFW which `dlopen`s `libEGL.dylib` by its bare leaf name.

**Fix:** branch on `APPLE` in addition to `VCPKG_TARGET_IS_WINDOWS`. On Apple, set `OUTPUT_NAME libGLESv2/libEGL` AND `PREFIX ""` so the final filename is `libGLESv2.dylib` / `libEGL.dylib`:

```cmake
if(APPLE)
    set_target_properties(GLESv2 PROPERTIES OUTPUT_NAME libGLESv2 PREFIX "")
elseif(NOT VCPKG_TARGET_IS_WINDOWS)
    set_target_properties(GLESv2 PROPERTIES OUTPUT_NAME libGLESv2_angle)
endif()
```

(Same for `EGL`.)

Two related portfile/forwarding bugs: the overlay portfile only forwards `-DVCPKG_TARGET_IS_WINDOWS=...` to the angle build, not `VCPKG_TARGET_IS_OSX`. So inside the angle CMakeLists, conditioning on `VCPKG_TARGET_IS_OSX` silently does nothing — use CMake's native `APPLE` variable instead.

**Scope:** only matters when building ANGLE shared on macOS, which is forced by our overlay triplet. Worth folding into the angle port if we ever upstream the overlay, otherwise stays as a permanent macOS-port-local patch.

## vcpkg overlay triplet for per-port linkage override

**Files:** `vcpkg-triplets/arm64-osx-pob.cmake`, `CMakeLists.txt` (Apple branch before vcpkg.cmake `include()`)

**Not a bug, but an architectural note worth recording.** The default `arm64-osx` triplet uses `VCPKG_LIBRARY_LINKAGE static`, which is the right global default — but ANGLE specifically must be built shared on macOS (so GLFW's EGL backend can `dlopen` it at runtime). vcpkg supports per-port linkage overrides via the `if(PORT STREQUAL "...")` block inside a triplet file, but the stock `arm64-osx` triplet lives in the vcpkg submodule and we shouldn't edit it. The clean solution is a project-local overlay triplet at `vcpkg-triplets/arm64-osx-pob.cmake` with a per-port override, plus `VCPKG_OVERLAY_TRIPLETS` and `VCPKG_TARGET_TRIPLET` set in CMakeLists.txt before the vcpkg.cmake include.

**One subtle gotcha worth documenting**: also set `VCPKG_HOST_TRIPLET` to the same custom triplet name. Otherwise vcpkg's `host_triplet != target_triplet` check considers the build a cross-compile (even though both are native arm64-osx), and the luajit portfile's `if(VCPKG_CROSSCOMPILING)` branch fires and passes `BUILDVM_X=` to luajit's Makefile but doesn't set `HOST_CC` for `host/minilua`. The luajit Makefile then links `host/minilua` with `:` (the noop shell builtin) instead of `cc`, silently produces no binary, and the install fails further down. Setting host==target avoids this.

This isn't a bug to upstream — it's the intended way to use custom triplets — but it's the kind of lore that costs an hour to rediscover, so worth a note.

## In-app updater hangs on macOS — single PoB Lua bug, one-line fix

This one surfaced when we tested the in-app updater end-to-end by pinning the PoB Lua submodule to v2.60.0 and letting the updater diff against current master (~220 files, including the new `TreeData/3_28*` directories). The updater sat at 100% CPU forever on what should have been a ~1-second file-copy phase.

Root cause is a single bug in **PoB Lua's `UpdateCheck.lua`**. Nothing in SimpleGraphic needs to change — `l_MakeDir` is fine as a single-directory primitive, and the per-segment MakeDir loop in `UpdateCheck.lua` is the intentional workaround that leverages it on Windows. The bug is that the workaround doesn't handle POSIX absolute paths correctly.

### The bug

**File:** PoB Lua repo `src/UpdateCheck.lua` (in the `for _, data in pairs(updateFiles)` loop, around line 307)

```lua
local dirStr = ""
for dir in data.fullPath:gmatch("([^/]+/)") do
    dirStr = dirStr .. dir
    MakeDir(dirStr)
end
```

`data.fullPath` is built as `scriptPath .. "/" .. name`.

- **On Windows**: `scriptPath` starts with a drive letter (`C:/...`), which is a non-`/` character. Lua's `[^/]+/` pattern happily captures `C:/` as the first segment, then `Program Files/`, then `Path of Building/`, etc. The accumulated `dirStr` stays **absolute** throughout. Each iteration's `MakeDir(dirStr)` creates one new directory whose parent was created in the previous iteration, so the singular `l_MakeDir` works at every step. The whole loop is effectively a Lua-side `create_directories`.

- **On POSIX (Linux + macOS)**: `scriptPath` starts with `/`. Lua's `[^/]+/` requires **at least one non-`/` char** before the `/`, so the leading `/` gets **skipped** and `gmatch` starts yielding from position 2 onward: `private/`, `tmp/`, `pob-install-wrapper/`, ..., `TreeData/`, `3_28/`. The accumulated `dirStr` is `private/tmp/...` — **relative**. `MakeDir` then resolves it against `cwd` (= `scriptPath` itself, set by PoB's launcher), so the loop creates a **phantom directory tree at `Resources/src/private/tmp/.../TreeData/3_28/`** while the real absolute destination `/private/tmp/.../TreeData/3_28/` is never created.

`UpdateApply.lua` then tries to copy the downloaded file to its absolute destination:

```lua
local dstFile
while not dstFile do
    dstFile = io.open(dst, "w+b")
end
```

The destination parent doesn't exist, `io.open` returns nil, and the retry loop spins at 100% CPU forever. (The infinite retry is its own latent bug — `io.open` failure on a missing directory should not retry forever — but fixing the MakeDir loop means io.open never fails in the first place.)

### Why it's invisible everywhere else

- **Windows**: drive letter starts with a non-`/` char → `gmatch` captures the whole absolute path correctly → per-segment loop works.
- **Linux (PR #98)**: doesn't ship a local manifest, so `Launch.lua` enters dev mode and the in-app updater never runs at all. The bug is latent.
- **macOS**: our port is the first and only environment that ships a manifest, runs the in-app updater against a real file diff, AND uses an absolute POSIX `scriptPath`. Everything lines up to expose it.

### The fix

One line. Seed `dirStr` with `/` when `fullPath` is a POSIX absolute path:

```lua
local dirStr = data.fullPath:sub(1,1) == "/" and "/" or ""
for dir in data.fullPath:gmatch("([^/]+/)") do
    dirStr = dirStr .. dir
    MakeDir(dirStr)
end
```

On Windows, the first char is `C` (or whatever the drive letter is), the conditional is false, `dirStr` stays `""`, and the loop behaves byte-identically to today's code. On POSIX absolute paths, the first char is `/`, `dirStr` is seeded with `/`, and the accumulated path stays absolute through the loop. On relative paths (should never happen for `fullPath`, but harmless anyway), the first char is a non-`/`, `dirStr` stays `""`, behavior unchanged.

No C++ change. No changes to SimpleGraphic. Single-file, single-line fix in PoB Lua.

### How this fork handles it

We can't modify PoB Lua upstream, and we don't maintain a fork of the Lua repo. Instead, the macOS bootstrap `mac_entry.lua` (in the wrapper repo) runs a `gsub` on `UpdateCheck.lua`'s source at load time — replacing the `local dirStr = ""` line with the conditional form — before handing the patched text to Lua's loader. The patch is applied at both entry points:

1. **`LoadModule` wrapper** for the first-run install path (Launch.lua:37 → `LoadModule("UpdateCheck")`, runs in the main Lua state)
2. **`LaunchSubScript` wrapper** for the regular CheckForUpdate path (Launch.lua:85 background check + 12-hour timer + Ctrl+U, runs in a fresh sub-script Lua state)

`UpdateCheck.lua` on disk is never modified, so the in-app updater's integrity check still passes and upstream can continue to ship updates to this file normally. The runtime patch survives every PoB Lua update.

### Upstream plan

Single PR against `PathOfBuildingCommunity/PathOfBuilding`. One-line change to `src/UpdateCheck.lua`. Safe on all platforms. Fixes a latent POSIX bug that was never exercised until macOS started shipping a bundle with a manifest. Zero SimpleGraphic changes required.

## SimpleGraphic writes its own config files to basePath instead of userPath

**Files:**
- `ui_main.cpp` (~lines 243, 491) — `SimpleGraphic.cfg` + `SimpleGraphicAuto.cfg`
- `engine/render/r_main.cpp` (~line 1085) — `imgui.ini` (Dear ImGui's window-state file)

**Bug:** three runtime-written config files are specified as bare relative paths:

```cpp
// ui_main.cpp:243 (load) and :491 (save)
core->config->LoadConfig("SimpleGraphic/SimpleGraphic.cfg");
core->config->LoadConfig("SimpleGraphic/SimpleGraphicAuto.cfg");
core->config->SaveConfig("SimpleGraphic/SimpleGraphic.cfg");
```

Dear ImGui similarly defaults `io.IniFilename = "imgui.ini"` (bare leaf name). All four paths are resolved against `cwd` at the time of `fopen`. And `ui_main_c::PCall` flips `cwd` between `scriptWorkDir` (during Lua execution) and `basePath` (via `sys->SetWorkDir()` with no arg, which `chdir`s back to `basePath`) between every Lua call. So at the moment SG's config save or ImGui's deferred autosave runs — both trigger from the main render loop, *outside* `PCall` — `cwd == basePath`. The files land at:

- `<basePath>/SimpleGraphic/SimpleGraphic.cfg`
- `<basePath>/SimpleGraphic/SimpleGraphicAuto.cfg`
- `<basePath>/imgui.ini`

**On Windows this is fine** because the PoB install dir is user-writable and there's no sealed manifest — rewriting files next to the binary works the way the code quietly assumes.

**On macOS this breaks in two ways:**

1. A code-signed `.app` bundle carries a sealed resource manifest (`Contents/_CodeSignature/CodeResources`). Any write inside `Contents/` invalidates it — `codesign --verify --deep --strict` fails afterward and Gatekeeper rejects the bundle if it's re-quarantined.
2. `/Applications/Foo.app` is not user-writable without admin. Once the DMG is installed the config writes fail with `EACCES` and PoB silently loses its window state, recent-build list, and ImGui state.

The same reasoning applies to any sandboxed Linux distribution format (flatpak, snap with classic confinement) and to future Windows AppContainer bundles.

**Root cause framing:** the issue isn't really "the paths are wrong", it's that `SetWorkDir()`'s `chdir`-flipping design makes cwd an unreliable anchor for any I/O site that wants "user-writable state". The safe rule for new code is **always resolve mutable paths against `sys->userPath`, never rely on cwd**. Existing code that predates that rule (these three call sites) should be migrated.

**Fix (upstream, ideal):** use `sys->userPath` as the base for mutable state on any platform where `FindUserPath()` returns non-empty (currently Linux and macOS):

```cpp
// ui_main.cpp sketch
std::filesystem::path sgCfgBase =
#if defined(__APPLE__) || defined(__linux__)
    sys->userPath / "SimpleGraphic";
#else
    sys->basePath;  // Windows: unchanged, preserves existing installs
#endif
std::filesystem::create_directories(sgCfgBase);
core->config->LoadConfig(sgCfgBase / "SimpleGraphic.cfg");
core->config->LoadConfig(sgCfgBase / "SimpleGraphicAuto.cfg");
// ... and the matching SaveConfig on shutdown
```

And after `ImGui::CreateContext()` in `r_main.cpp`:

```cpp
static std::string s_imguiIniPath;  // must outlive the ImGui context
#if defined(__APPLE__) || defined(__linux__)
s_imguiIniPath = (sys->userPath / "imgui.ini").string();
ImGui::GetIO().IniFilename = s_imguiIniPath.c_str();
#endif
```

`sys->userPath` is already computed at construction (`sys_main.cpp:677` via `FindUserPath()`), so no new discovery logic is required.

**Fix (what we actually shipped in the macOS wrapper):** a `POB_MAC_USER_DIR` env var set by our launcher that both call sites read, falling back to `basePath` when unset. Chosen over the `sys->userPath` variant because:

1. It's a *minimal* diff (~10 lines across the two files, no headers touched). Upstream merges stay clean.
2. It lets the wrapper pick the subdir name (`PathOfBuildingMac/` in our case) without baking a name into upstream code that might not match whatever naming upstream prefers.
3. It follows the existing env-var pattern already in SG (`SG_BASE_PATH`).

The env-var approach is what we'd suggest sending first as a conservative patch. The `sys->userPath` rewrite is the cleaner long-term fix if upstream wants to pick a subdir name and commit to it.

**Side observation — `SetWorkDir()` cwd flipping is a latent footgun.** The pattern in `ui_main_c::PCall`:

```cpp
sys->SetWorkDir(scriptWorkDir);  // flip cwd for Lua
lua_pcall(L, ...);
sys->SetWorkDir();                // flip back to basePath
```

means any future SG-side file I/O written with a relative path will implicitly land at `basePath` — not at `cwd` as a reader might assume, and not at the script's working dir either. Adding a one-line comment near `SetWorkDir(std::filesystem::path const&)` in `sys_main.cpp:402` documenting the invariant (`"Default cwd after any SetWorkDir()-with-no-arg is basePath; relative paths used outside of Lua callbacks resolve there"`) would help future contributors avoid repeating this pattern. Tiny doc-only change, no behavior impact.

**Scope:** both parts are genuinely upstream-worthy. The config-path fix is one of the two things blocking code-signed macOS distribution (the other being our App Support relocation for the `src/` tree, which is wrapper-local and not upstream material). The `SetWorkDir` doc-comment is a freebie that could ride along in the same PR.

## libs/luautf8: C23 label-followed-by-declaration rejected by older clang

**File:** `libs/luautf8` submodule pin in `SimpleGraphic/.gitmodules`

**Bug:** upstream `luautf8`'s `lutf8lib.c` at our pinned commit (`bdd3d7f`, 2023-10-05, "Add 'grapheme_indices' function") has a `build_string:` label followed immediately by `luaL_Buffer buff;` inside `Lutf8_normalize_nfc`. In C89 through C17, a label must be followed by a *statement*, not a *declaration* — so strict parsers reject it as `error: expected expression`. This was only standardized in **C23**.

Newer Apple clang (Xcode 16.3+, clang ~17+) accepts it as a C23 extension with `-Wc23-extensions` warning. Older Apple clang (Xcode 15 series, shipping on GitHub's `macos-14` runners) rejects it outright as an unrecoverable parse error. This caused our first CI run on `macos-14` to fail during the `lua-utf8` build step, even though local builds on Xcode 16 succeeded with just a warning.

**Fix:** **upstream already fixed this.** starwing/luautf8 PR #49 flagged the same issue in January 2024; the PR was closed because the maintainer fixed it directly on master (added `build_string: ;` — a null statement to satisfy any C standard's label-must-be-statement rule). As of `luautf8` master (~36 commits ahead of our pin as of 2026-04), the problem is gone.

**Recommended action for upstream SimpleGraphic:** bump the `libs/luautf8` submodule pointer to a recent master commit. Beyond fixing the parse error, the 36 commits include Lua 5.5 compat, a new `widthlimit` API, fixes to UTF-8 offset handling, and several bug fixes. Minor risk: there's one commit marked `feat!` (`feat!: add widthlimit API and modernize width functions (v0.2.0)`) — worth a read-through before bumping in case the breaking change touches functions PoB actually calls.

**What we did in this wrapper instead:** switched our CI runner from `macos-14` to `macos-15`, which ships Xcode 16 and accepts the current pin's code as a C23 extension with just a warning. This sidesteps the issue without touching the submodule. The upstream bump remains the more robust fix for anyone building SG with older Apple clang or in a stricter C standard mode, so it's worth recording here even though it isn't blocking us.

**Scope:** one-line submodule pointer change in `PathOfBuilding-SimpleGraphic/.gitmodules` + a `git submodule update`. No code changes to SG itself. Zero risk to Windows builds. Low-priority for upstream since Windows MSVC doesn't trip on this and Linux GCC trips on it only in strict modes.
