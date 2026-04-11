# Path of Building — macOS Port Reference

A technical reference for porting Path of Building (PoB) to macOS. This file is a working document, not upstream documentation.

## Architecture in one sentence

PathOfBuilding is ~95% pure Lua running inside SimpleGraphic, a C++ host DLL that provides windowing, OpenGL ES rendering, input, file I/O, and exposes a ~70-function API to Lua. The Lua side is already cross-platform; the porting work is essentially all in this SimpleGraphic repo.

## How the two repos relate

```
PathOfBuilding (../PathOfBuilding)              PathOfBuilding-SimpleGraphic (here)
├── src/Launch.lua  ← entry point          →    win/entry.cpp::RunLuaFileAsWin()
├── src/Modules/*.lua (build calc, UI)            ↓
├── src/Classes/*.lua (controls)                 sys_main_c (main loop, GLFW poll)
├── src/Data/*.lua  (item DB)                     ↓
├── runtime/                                     core_main_c → ui_main_c
│   ├── Path of Building.exe (tiny launcher)      ↓
│   ├── SimpleGraphic.dll  ← built from here     ui_api.cpp (~2300 lines of sol2 bindings)
│   ├── lua51.dll, glfw3.dll, libGLES*.dll        ↓
│   └── Update.exe                               r_main.cpp / r_texture / r_font (GLES2 renderer)
└── manifest.xml  ← platform="win32" tagged
```

The PoB launcher exe simply `LoadLibrary`s `SimpleGraphic.dll` and calls `RunLuaFileAsWin(argc, argv)`, which spins up the GLFW window, the renderer, the Lua VM (LuaJIT), and runs `Launch.lua`. From that point everything is Lua calling back into C++ via sol2 bindings.

## Languages & dependencies

- **Lua side (PoB repo)**: Lua 5.1 / LuaJIT, ~2 MB of `.lua`
- **C++ side (this repo)**: C++17, vcpkg-managed
  - **Graphics**: ANGLE (GL ES runtime — has Metal backend on macOS), GLFW, gli
  - **Scripting**: LuaJIT, sol2
  - **Imaging**: stb_image, libjpeg-turbo, libpng, libwebp, giflib
  - **Other**: curl, fmt, re2, zstd, zlib, ms-gsl
  - **Compression**: compressonator (BC3/BC7 texture compression)
  - **UI**: ImGui (debug overlay)
- **Lua extension dylibs PoB ships**: `lcurl`, `lua-utf8`, `luasocket`, `lzip`

## Entry points & main loop

- **DLL export**: `win/entry.cpp` exports `extern "C" RunLuaFileAsWin(int argc, char** argv)` (single symbol).
- **Init**: `entry.cpp` constructs `sys_main_c`, then loops `while (sys->Run(argc, argv));`.
- **Main loop** (`engine/system/win/sys_main.cpp` ~lines 634-740):
  ```
  Initialize console, video, core (which boots UI, renderer, Lua)
  while (!exitFlag):
      if minimized: glfwWaitEventsTimeout(0.1)
      else:         glfwPollEvents()
      if glfwWindowShouldClose(): Exit()
      core->Frame()  // runs Lua OnFrame, renders
  Shutdown
  ```
- **Lua callbacks** (called by C++ into Lua): `OnInit`, `OnFrame`, `OnKeyDown(key, doubleClick)`, `OnKeyUp`, `OnChar`, `CanExit`, `OnExit`.

## Directory structure (this repo)

```
PathOfBuilding-SimpleGraphic/
├── CMakeLists.txt              [9149 lines — already has APPLE branches & links CoreFoundation/AppServices]
├── vcpkg.json                  [dependency manifest]
├── win/entry.cpp               [DLL export RunLuaFileAsWin]
├── engine/
│   ├── system/
│   │   ├── sys_main.h          [interface — sys_IMain]
│   │   ├── sys_video.h         [interface — sys_IVideo]
│   │   ├── sys_opengl.h
│   │   ├── sys_console.h
│   │   └── win/                ← all platform-specific code lives here
│   │       ├── sys_local.h
│   │       ├── sys_main.cpp        [740 lines, Win32-leaning]
│   │       ├── sys_video.cpp       [769 lines, Win32-leaning]
│   │       ├── sys_console.cpp     [353 lines — Win32 GUI debug console]
│   │       ├── sys_console_unix.cpp[158 lines — stderr fallback, already cross-plat]
│   │       ├── sys_opengl.cpp      [71 lines — GLFW based, portable]
│   │       └── sys_macos.mm        [13 lines — STUB, only OpenURL]
│   ├── render/
│   │   ├── r_main.cpp          [2083 lines — renderer core, GL ES 2.0]
│   │   ├── r_texture.cpp       [707 lines]
│   │   └── r_font.cpp          [474 lines]
│   ├── core/
│   │   ├── core_main.cpp       [engine main]
│   │   ├── core_video.cpp
│   │   ├── core_image.cpp      [527 lines]
│   │   ├── core_config.cpp
│   │   └── core_compress.cpp
│   └── common/                 [common.cpp, console.cpp, streams.cpp, memtrak3, base64]
├── ui_api.cpp                  [2298 lines — sol2 Lua bindings, the API surface PoB calls]
├── ui_main.cpp                 [591 lines — UI manager]
├── ui_console.cpp / ui_debug.cpp / ui_subscript.cpp
├── dep/                        [stb, glad, glm, imgui, compressonator]
├── libs/                       [Lua-cURLv3, luausocket, luautf8, LZip]
└── vcpkg/, vcpkg-ports/        [vcpkg manifest setup]
```

## What's already portable (good news)

- **All of `../PathOfBuilding/src/`** — pure Lua, forward slashes, no Win32 assumptions outside `src/Export/` (a dev-only data extraction tool).
- **Renderer**: OpenGL ES 2.0 via ANGLE + Glad. No DirectX. ANGLE has a Metal backend on macOS.
- **Windowing/input**: GLFW (native macOS support).
- **Lua bindings**: sol2 + LuaJIT.
- **File I/O**: `std::filesystem` + RE2 for glob.
- **Image loading**: stb_image.
- **CMake + vcpkg**: `CMakeLists.txt` already has `if (APPLE)` branches and links `CoreFoundation` + `ApplicationServices`. Scaffolding is in place.

## What's Windows-only — the actual port work

All concentrated in `engine/system/win/`:

| File | Lines | What it does | Difficulty |
|---|---|---|---|
| `sys_main.cpp` | 740 | Timer, threads, key map, clipboard, `ShellExecuteEx`, SEH translator | **Medium** — most is GLFW-backed; replace `ShellExecuteEx` with `posix_spawn` / `NSTask`, drop SEH, port `SetThreadPriority` |
| `sys_video.cpp` | 769 | Window, monitors, cursor, **HICON loading from .rc resources**, DPI via `GetDC` | **Medium-High** — icon loading is messiest; DPI can use `NSScreen` or GLFW's framebuffer scale |
| `sys_console.cpp` | 353 | Win32 GUI debug console (HWND + WndProc) | **High** — but `sys_console_unix.cpp` (158 lines, stderr-only) already exists. Easiest path: use the unix one |
| `sys_macos.mm` | 13 | **Stub** — only implements `OpenURL` via `LSOpenCFURLRef` | Needs to grow |
| `libs/luausocket/wsocket.c` | — | Win32 sockets | **Medium** — luasocket has standard BSD socket support; toggle build to `usocket.c` |
| `win/entry.cpp` | 98 | DLL export | **Low** — produce `.dylib` with same C symbol |

CMake currently does:
```cmake
if (APPLE)
    set (SIMPLEGRAPHIC_PLATFORM_SOURCES "engine/system/win/sys_macos.mm")
endif()
```
which is essentially no platform implementation. The Windows files in `engine/system/win/` need to either be split into per-platform variants or grow `#ifdef` branches.

## SimpleGraphic API surface PoB depends on

PoB calls these from Lua (visible in `../PathOfBuilding/src/HeadlessWrapper.lua` as a stub set, used throughout `src/Modules/`). All implemented in `ui_api.cpp`.

- **Window/Render**: `RenderInit`, `GetScreenSize`, `GetVirtualScreenSize`, `GetScreenScale`, `SetDrawColor`, `SetDrawLayer`, `SetViewport`, `DrawString`, `DrawStringWidth`, `DrawImage`, `DrawImageQuad`, `DrawStringCursorIndex`, `StripEscapes`, `NewImageHandle`, `SetClearColor`, `SetWindowTitle`, `ConExecute`
- **Input**: `IsKeyDown`, `GetCursorPos`, `SetCursorPos`, `ShowCursor`, `Copy`, `Paste`
- **FS**: `GetScriptPath`, `GetRuntimePath`, `GetUserPath`, `GetWorkDir`, `SetWorkDir`, `MakeDir`, `RemoveDir`, `NewFileSearch`
- **Process/exec**: `LoadModule`, `PLoadModule`, `LaunchSubScript`, `AbortSubScript`, `IsSubScriptRunning`, `SpawnProcess`, `PCall`
- **Misc**: `GetTime`, `OpenURL`, `TakeScreenshot`, `Restart`, `Exit`, `ConPrintf`, `ConClear`, `Deflate`, `Inflate`, `GetDPIScaleOverridePercent`, `SetDPIScaleOverridePercent`, `GetCloudProvider`

## Non-code pieces to handle

1. **`GetUserPath()` semantics**: should return `~/Library/Application Support/Path of Building/` on macOS.
2. **PoB's `manifest.xml` / `UpdateCheck.lua`**: tagged `platform="win32"`. To distribute mac builds via PoB's auto-updater, add `platform="macos"` source entries and host `.dylib`s. Until then, run from a dev checkout.
3. **`Update.exe`**: spawned from `Launch.lua:329` as `GetRuntimePath()..'/Update'`. Need a tiny mac equivalent or disable in-place updates initially.
4. **PoB launcher exe**: lives in a separate `PathOfBuildingInstaller` repo. For mac, ship a `.app` bundle whose binary just `dlopen`s `SimpleGraphic.dylib` and calls `RunLuaFileAsWin`. Trivial.
5. **Lua extension dylibs**: `lcurl`, `lua-utf8`, `luasocket`, `lzip`. All have working macOS builds via vcpkg, but `luasocket`'s Windows-specific `wsocket.c` needs to switch to `usocket.c`.

## Files PoB references that touch platform assumptions

- `src/Launch.lua:329` — `SpawnProcess(GetRuntimePath()..'/Update', ...)` — process spawn for updater
- `src/UpdateCheck.lua:156-170` — platform detection via `localPlatform` attribute
- `src/Modules/Main.lua:85-95` — user data path detection
- `src/Export/psg.lua` — Windows-only `xcopy` and backslashes (dev tool, not runtime)
- `manifest.xml` — `platform="win32"` tagged sources

## Suggested attack plan

1. Get the project building on macOS via CMake — even if it produces a broken `.dylib`. This forces every `#include <windows.h>` into the open.
2. Stub out `sys_console.cpp` by extending `sys_console_unix.cpp` — kill the GUI console for now.
3. Split `engine/system/win/sys_main.cpp` and `sys_video.cpp` into a portable `engine/system/glfw/` core + a tiny `_win.cpp` / `_macos.mm` for the actually-Win32 bits (icon loading, `ShellExecuteEx`, SEH, `SetThreadPriority`, `GetUserPath`).
4. Make `wsocket.c` → `usocket.c` swap conditional in CMake.
5. Build the Lua side: `cmake --build`, then point a checkout of `../PathOfBuilding` at the resulting `.dylib` via a tiny launcher.
6. Iterate on rendering/font/cursor issues until `Launch.lua` actually paints a window.

## Prior art: PR #98 (Linux native port)

[PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic#98](https://github.com/PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic/pull/98) — branch `velomeister:linux-port` — open as of 2026-04-10, mergeable, 39 files / +1581 / -42. **This does ~80% of the macOS work and we should base our port on its branch, not master.**

### What carries over to macOS unchanged

- **`engine/common/base64.{c,h}`, `engine/core/core_compress.cpp`, `engine/render/{r_font,r_main,r_texture}.cpp`** — stdlib header additions for GCC 15. Clang on modern macOS hits the same missing-implicit-include issues.
- **`engine/render/r_texture.cpp`** — `4ull` → `size_t{4}` narrowing fix.
- **`engine/render/r_main.cpp`** — Win32 `Sleep(1)` → `std::this_thread::sleep_for`.
- **`engine/system/win/sys_main.cpp`**:
  - Already has `#elif __APPLE__ && __MACH__` branches and includes `<libproc.h>`.
  - `Error("Exception: ", e.what())` → `Error("Exception: %s", e.what())` format-string fix.
  - The non-Windows `pwd.h` user-path code path applies to mac.
  - `SpawnProcess` POSIX `fork`/`execvp` impl works on mac as-is.
- **`engine/common/common.cpp`** — `IndexUTF8ToUTF32` un-`#ifdef _WIN32`-ing.
- **`CMakeLists.txt`** — most changes are `if (NOT WIN32)` not `MATCHES "Linux"`, so they cover macOS automatically:
  - `POSITION_INDEPENDENT_CODE ON` on `cmp_core` and `imgui`
  - `PREFIX ""` on Lua module targets so `require("socket")` finds `socket.dylib`
  - `usocket.c` instead of `wsocket.c`; Windows-only `wsock32`/`ws2_32` link deps
  - `LIBRARY DESTINATION "."` so `.dylib`s install to prefix root
  - `zstd::libzstd_static` fallback via generator expression
- **`vcpkg-ports/ports/angle/cmake-buildsystem/PlatformMac.cmake`** — **already in the PR**. Lists Metal backend (`USE_METAL`), Cocoa frameworks (CoreGraphics, Foundation, IOKit, IOSurface, Quartz, Metal), `libangle_mac_sources`, etc. The PR author scaffolded ANGLE-for-Mac even though they didn't ship a mac binary.
- **`vcpkg-ports/ports/luajit/`**:
  - `LUAJIT_ENABLE_GC64` workaround for high `dlopen` addresses — likely needed on mac for the same reason.
  - `pob-wide-crt.patch` null-`getenv` crash fix — needed on any non-Windows.
- **`linux/launcher.c`** — exact pattern to copy for `macos/launcher.c`.

### What's specifically Linux and needs swapping

| Linux thing | macOS replacement |
|---|---|
| `/proc/self/exe` (in `sys_main.cpp` and `launcher.c`) | `_NSGetExecutablePath` or `proc_pidpath` (already in `<libproc.h>`) |
| `xdg-open` for `PlatformOpenURL` | `LSOpenCFURLRef` — already implemented in `sys_macos.mm` |
| `IMGUI_IMPL_OPENGL_ES3` + system `GLESv2` | Stick with ANGLE + `IMGUI_IMPL_OPENGL_ES2`, since ANGLE has a Metal backend on mac (the new `PlatformMac.cmake` enables it). PR conditioned this on `MATCHES "Linux"` so default already works on mac. |
| `-Wl,--allow-multiple-definition` (GNU ld, for lcurl `luaL_setfuncs` duplicate vs LuaJIT) | ld64 doesn't support this — patch `l52util.c` to `#ifndef`-out the duplicate, or use `-Wl,-undefined,dynamic_lookup` |
| `-Wno-template-body` (GCC 15 sol2 warning) | Clang doesn't have this warning — skip on Apple |
| `-export-dynamic` linker flag | macOS exports symbols by default; should be a no-op or use `-Wl,-export_dynamic` on ld64 |
| `linux/launcher.c` → `libSimpleGraphic.so` | `macos/launcher.c` → `libSimpleGraphic.dylib`, eventually wrapped in a `.app` bundle |
| `SG_BASE_PATH` env var | Same env var works fine; only the executable-path resolution differs |

### Updated attack plan (rebased onto PR #98)

1. **Fetch and check out** the PR branch: `gh pr checkout 98` (or fork/rebase locally).
2. **Get a Linux-style build going on macOS first** by generalizing `if (CMAKE_SYSTEM_NAME MATCHES "Linux")` → `if (UNIX)` or `if (NOT WIN32)` where the underlying logic is POSIX-not-Linux-specific.
3. **Add `#elif __APPLE__` branches** in `sys_main.cpp` next to every `#elif __linux__` for: `FindBasePath` (use `_NSGetExecutablePath`), `PlatformOpenURL` (call into the existing `sys_macos.mm` `LSOpenCFURLRef` impl).
4. **Clone `linux/launcher.c` → `macos/launcher.c`**: replace `/proc/self/exe` with `_NSGetExecutablePath` and `.so` with `.dylib`. Wire it into CMake under `if (APPLE)`.
5. **Resolve the `lcurl` duplicate-symbol issue** without `--allow-multiple-definition`: probably by patching `l52util.c` to guard against LuaJIT 5.2-compat exporting `luaL_setfuncs`.
6. **Build ANGLE for macOS** via the existing `PlatformMac.cmake` with `USE_METAL=ON`. This is the largest unknown — may need iteration on the angle vcpkg port.
7. **Build LuaJIT with `LUAJIT_ENABLE_GC64`** in the macOS branch of the LuaJIT port.
8. **Iterate** on font/window/cursor/input until `Launch.lua` paints a window.
9. **Wrap in a `.app` bundle** for distribution (Info.plist, icon, code signing if needed).
