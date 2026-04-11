# Path of Building — macOS Port Reference

A working document for the macOS port of Path of Building. Not upstream documentation. For upstream-worthy bugs and their fixes, see [UPSTREAM_NOTES.md](UPSTREAM_NOTES.md).

## Architecture in one sentence

PathOfBuilding is ~95% pure Lua running inside SimpleGraphic, a C++ host library (`libSimpleGraphic.dylib` on macOS) that provides windowing, OpenGL ES rendering, input, file I/O, and exposes a ~70-function API to Lua via sol2. The Lua side is already cross-platform; essentially all the porting work is in SimpleGraphic and a small wrapper around it.

## Repo layout

This is a three-repo project:

```
PathOfBuilding-Mac                        ← this repo (the wrapper)
├── CMakeLists.txt                         top-level build — orchestrates SG + launcher + bundle
├── macos/
│   ├── launcher.cpp                       the .app's main binary (~340 lines, C++17 + std::filesystem)
│   ├── mac_entry.lua                      Lua bootstrap — patches PoB's in-app updater before Launch.lua
│   ├── Info.plist.in                      bundle Info.plist template
│   ├── AppIcon.icns                       app icon
│   ├── entitlements.plist                 hardened-runtime entitlements (allow-jit + dylib loading)
│   ├── sign.sh                            codesign dylibs → bundle with entitlements
│   └── make-dmg.sh                        hdiutil DMG packaging
├── SimpleGraphic/                         ← submodule: stevschmid/PathOfBuilding-SimpleGraphic @ macos-port
│                                            our fork; all engine-side porting work lives here
└── PathOfBuilding/                        ← submodule: PathOfBuildingCommunity/PathOfBuilding @ v2.63.0
                                             upstream PoB Lua app; we never patch this
```

The wrapper's top-level `CMakeLists.txt` does:

1. `add_subdirectory(SimpleGraphic)` → builds `libSimpleGraphic.dylib` + four helper Lua modules (`lcurl.dylib`, `lua-utf8.dylib`, `socket.dylib`, `lzip.dylib`)
2. Adds a `PathOfBuilding` executable target (from `macos/launcher.cpp`), configured as a `MACOSX_BUNDLE` target
3. Install rules that deposit everything into a `Path of Building.app/Contents/` layout and pull the PoB Lua tree out of the `PathOfBuilding/` submodule into `Contents/Resources/src`
4. A configure-time transform of upstream's `manifest.xml` (strips `runtime="win32"` entries, adds `branch="master" platform="macos"` to `<Version>`)

## Bundle layout (what the DMG ships)

```
Path of Building.app/
├── Contents/
│   ├── Info.plist                          CFBundleIdentifier = ch.spidy.PathOfBuildingMac
│   ├── MacOS/
│   │   ├── Path of Building                our launcher (launcher.cpp)
│   │   ├── libSimpleGraphic.dylib          SG engine
│   │   ├── libEGL.dylib / libGLESv2.dylib  ANGLE w/ Metal backend
│   │   └── lcurl lua-utf8 socket lzip      Lua helper modules (.dylib)
│   ├── Resources/
│   │   ├── AppIcon.icns
│   │   ├── SimpleGraphic/Fonts/            bitmap fonts
│   │   ├── lua/                            runtime/lua from PoB (dkjson etc.)
│   │   └── src/                            bundled PoB Lua tree — "factory default"
│   │       ├── Launch.lua                  upstream entry
│   │       ├── mac_entry.lua               our bootstrap (not in any manifest)
│   │       ├── manifest.xml                generated at configure time from upstream
│   │       ├── changelog.txt               moved from PoB repo root (see below)
│   │       ├── help.txt                    ↑
│   │       ├── LICENSE.md                  ↑
│   │       └── Modules/ Classes/ Data/ TreeData/ …
│   └── _CodeSignature/CodeResources        sealed manifest from `codesign`
```

`Contents/` is **completely read-only after signing**. All mutable state goes elsewhere — see next section.

## Where runtime state actually lives

Two App Support directories, deliberately separate:

```
~/Library/Application Support/
├── Path of Building/                       PoB's own user data, unchanged from upstream
│   ├── Settings.xml                         window prefs, recent builds, UI scale, cloud provider
│   └── Builds/                              user's saved builds
│
└── PathOfBuildingMac/                      our wrapper runtime state
    ├── .bundle_version                     refresh-detection marker (compared to compile-time constant)
    ├── src/                                relocated Lua tree — this is PoB's live working directory
    │   └── …                                updater writes here, cfg files resolve here
    ├── SimpleGraphic/
    │   ├── SimpleGraphic.cfg               SG's window state
    │   └── SimpleGraphicAuto.cfg
    └── imgui.ini                           Dear ImGui window state
```

### Why two directories

- **`Path of Building/`** is what PoB's `Main.lua` writes via `GetUserPath() .. "Path of Building/"` — the user-facing data dir. We don't touch it, and if an official PoB mac build ever ships, its user data can coexist here without colliding.
- **`PathOfBuildingMac/`** is ours. Wrapper-specific runtime state that the user never has to care about — if they delete it, the launcher rebuilds it from the bundle on next launch.

## launcher.cpp

`macos/launcher.cpp` is the binary inside `Contents/MacOS/Path of Building`. C++17, ~340 lines, uses `std::filesystem` for the relocation logic. Deliberately not Objective-C so we don't add a new language to the SG+PoB project surface.

What it does, in order:

1. **Resolve its own directory** via `_NSGetExecutablePath` + `realpath`.
2. **Pre-load ANGLE** (`libGLESv2.dylib`, then `libEGL.dylib`) via absolute-path `dlopen`, so GLFW's later `dlopen("libEGL.dylib", ...)` by bare leaf name finds the already-loaded image. dyld does not search LC_RPATH or `@loader_path` for bare-name dlopen, so this is the cleanest way to make GLFW find ANGLE without polluting `DYLD_LIBRARY_PATH`.
3. **Load `libSimpleGraphic.dylib`** from the same directory and `dlsym` the single export `RunLuaFileAsWin`.
4. **Detect bundle vs. dev mode** by checking if `<exeDir>/../Resources/src/Launch.lua` exists. In bundle mode the launcher ignores argv entirely and auto-discovers paths; in dev mode argv[1] is a path to a Lua script and paths are derived relative to it (matches PR #98's `linux/launcher.c` pattern).
5. **Relocate `src/` into App Support** (bundle mode only) — see next section.
6. **Set environment variables** for SG: `SG_BASE_PATH` (always points at bundle `Contents/Resources` — fonts and runtime lua stay in the bundle as read-only data), `POB_MAC_USER_DIR` (points at `PathOfBuildingMac/`), `LUA_PATH`, `LUA_CPATH`.
7. **Call `RunLuaFileAsWin(1, { scriptPath, NULL })`** where `scriptPath` is `<AppSupport>/PathOfBuildingMac/src/mac_entry.lua`. SG then sets its internal `scriptPath` to the parent directory and everything downstream runs out of App Support.

`CMAKE_CXX_STANDARD 17` is set at wrapper scope in the top-level `CMakeLists.txt` because `std::filesystem` and `std::optional` need it.

## RelocateRuntime — the Option B flow

Every bundle-mode launch calls `RelocateRuntime(bundleSrc)`:

1. Compute `~/Library/Application Support/PathOfBuildingMac/` (via `$HOME` with `getpwuid` fallback — same pattern as SG's `sys_main_c::FindUserPath`).
2. Read the marker `PathOfBuildingMac/.bundle_version`. Compare string-equality against `POB_BUNDLE_VERSION_STRING` (a compile-time constant set from the `POB_BUNDLE_VERSION` CMake variable).
3. **If marker matches**: no-op for `src/`. The extracted tree is up-to-date for this DMG, and any in-app updater state accumulated since is preserved.
4. **If marker is missing or stale**: `fs::remove_all(appSrc)` then `fs::copy(bundleSrc, appSrc, fs::copy_options::recursive)`, then write the new marker. Logged to stderr as `RelocateRuntime: bundle version changed (marker=X, bundle=Y), refreshing …`.
5. **Always** overwrite `PathOfBuildingMac/src/mac_entry.lua` from the bundle. It's our bootstrap file, PoB's updater never touches it (excluded from the manifest), and keeping it always-fresh lets dev iteration on `mac_entry.lua` take effect on next launch without needing a `POB_BUNDLE_VERSION` bump.

### Why this shape

PoB on Windows writes updater-fetched Lua files directly into its install tree, because on Windows the install dir is user-writable and there's no sealed manifest. On macOS:

- `/Applications/Path of Building.app` is not user-writable without admin (the updater would `EACCES`)
- A signed bundle's `_CodeSignature/CodeResources` seals everything inside `Contents/`; any write invalidates `codesign --verify --deep --strict`

Option B splits the tree: the bundle ships a read-only "factory default" Lua tree, and `src/` lives for real at a user-writable App Support location that the updater can freely modify. The signed bundle is never touched after install.

### Version-bump scenario (validated end-to-end)

1. User installs v0.1 of our DMG (bundled PoB 2.63.0):
   - `.bundle_version` missing → refresh → `src/` = PoB 2.63.0, marker = `2.63.0`
2. User runs PoB, in-app updater pulls PoB 2.64.0:
   - Updater writes to `PathOfBuildingMac/src/` directly. Marker unchanged.
3. User relaunches v0.1:
   - Marker `2.63.0` matches bundle version → no-op, preserves in-app 2.64.0
4. User downloads v0.2 DMG (bundled PoB 2.65.0), replaces `/Applications/Path of Building.app`:
   - Marker `2.63.0` ≠ bundle `2.65.0` → refresh fires
   - `src/` wiped, re-populated from bundle 2.65.0. In-app-updated 2.64.0 state discarded.
   - A new DMG is an explicit "reset to this baseline" operation — that's the intended semantics.
5. User in-app updates to 2.66.0, etc. — cycle repeats.

Verified by pinning the PoB submodule to v2.60.0, bumping `POB_BUNDLE_VERSION` to match, building, installing, launching, letting the in-app updater run to master, and confirming: `src/` content updated to 2.63.0, bundle untouched (1135 files still, same timestamps), `codesign --verify --deep --strict` still exit 0.

## POB_MAC_USER_DIR — the SG contract

Three files that SG writes at runtime — `SimpleGraphic/SimpleGraphic.cfg`, `SimpleGraphic/SimpleGraphicAuto.cfg`, `imgui.ini` — are specified in SG's code as bare cwd-relative paths. `ui_main_c::PCall` flips cwd between `scriptWorkDir` (during Lua) and `basePath` (between Lua calls), so at save time cwd is `basePath` and the files land inside `Contents/Resources/`. See [UPSTREAM_NOTES.md — SimpleGraphic writes its own config files to basePath instead of userPath](UPSTREAM_NOTES.md) for the full analysis.

Our wrapper patches SG to read an env var `POB_MAC_USER_DIR`:

- `ui_main.cpp`: file-static `s_sgCfgBase` resolved once in `Init`, used in both Init (load) and Shutdown (save)
- `r_main.cpp`: right after `ImGui::CreateContext()`, sets `io.IniFilename` to an absolute path under `$POB_MAC_USER_DIR/imgui.ini`

When the env var is unset (dev mode, non-macOS, or anyone using SG without our launcher), both files fall back to `sys->basePath` and preserve the legacy behavior. The patch is ~15 lines total with no header changes, specifically shaped for merge-friendliness with upstream SG.

## CMake install rules — top-level PoB data files

PoB's `src/Modules/Main.lua:1185` reads `changelog.txt` / `help.txt` / `LICENSE.md` relative to cwd (= `src/`) in installed mode:

```lua
local changelogName = launch.devMode and "../changelog.txt" or "changelog.txt"
```

These files live at the **PoB repo root**, not in `src/`. The Windows installer moves them into `src/` as a packaging step. Our CMakeLists replicates that move:

```cmake
install(FILES
    "${POB_LUA_TREE}/changelog.txt"
    "${POB_LUA_TREE}/help.txt"
    "${POB_LUA_TREE}/LICENSE.md"
    DESTINATION "${POB_RES_DEST}/src"
)
```

Without this, PoB's updater reports "Update available" on first launch because `UpdateCheck.lua` sees `part="default"` files as missing (their `fullPath = scriptPath / name` lookups in `src/` come up empty).

### Lore: CRLF/LF sha1 tolerance in UpdateCheck.lua

PoB's `manifest.xml` is generated on a Windows build machine where text files have CRLF line endings, so its `sha1="..."` attributes are hashes of CRLF content. On a mac install those files have LF endings. The shas *don't match directly*:

| File | LF sha (what's on disk on mac) | Manifest claims (CRLF) |
|---|---|---|
| `changelog.txt` | `f5aa2be6…` | `1f9deab0…` |
| `help.txt` | `b1287f42…` | `e486cb63…` |
| `LICENSE.md` | `be578b61…` | `c77635aa…` |

`UpdateCheck.lua:191/257` handles it:

```lua
if data.sha1 ~= sha1(content) and data.sha1 ~= sha1(content:gsub("\n", "\r\n")) then
```

It tries both LF and LF→CRLF hashes. That's a built-in cross-platform tolerance that's been in PoB since before our port. It's why shipping our LF-ending files against the bundled CRLF-sha manifest works — the updater silently accepts the CRLF match and moves on. This only kicks in when the file exists, though, which is why shipping them at all is necessary.

## Bundle manifest generation

Upstream's `manifest.xml` has Windows-specific entries (`runtime="win32"`) and a `<Version>` element with only `number="..."`. At CMake configure time we transform it:

1. Strip every line matching `runtime="win32"` (prevents the updater from trying to download `.dll` / `.exe`).
2. Rewrite `<Version number="..." />` → `<Version number="..." branch="master" platform="macos" />` so `Launch.lua` recognizes installed mode and uses the correct source URLs.
3. Write the result to `${CMAKE_BINARY_DIR}/manifest.xml`, which the install rules deposit into `Contents/Resources/src/manifest.xml`.

`CMAKE_CONFIGURE_DEPENDS` on `${POB_LUA_TREE}/manifest.xml` ensures the transform re-runs when the PoB submodule bumps.

`macos/mac_entry.lua` applies the same filter at runtime for defensive reasons — when the in-app updater fetches a fresh manifest from master, it needs to be filtered before UpdateCheck.lua starts iterating.

## Signing, entitlements, DMG

### Entitlements (`macos/entitlements.plist`)

- `com.apple.security.cs.allow-jit` — required so LuaJIT's `mmap(MAP_JIT)` calls succeed under hardened runtime. Without it, JIT traces fall back to the interpreter and passive-tree clicks stall for ~1.5s each.
- `com.apple.security.cs.allow-unsigned-executable-memory` — companion to `allow-jit` for the executable pages LuaJIT writes.
- `com.apple.security.cs.disable-library-validation` — required because our launcher explicitly `dlopen`s `libEGL.dylib` and `libGLESv2.dylib`. Under ad-hoc signing this trips the "different Team IDs" library-validation check. Under Developer ID signing it would pass normally, but keeping the entitlement consistent across both ad-hoc and release builds simplifies the signing pipeline. Notarization accepts this entitlement for apps that dlopen their own bundled dylibs.

### sign.sh

1. Sign every `.dylib` in `Contents/MacOS/` first (leaf-first).
2. Sign the bundle root with `--entitlements macos/entitlements.plist --options runtime`. Signing a `.app` bundle *is* signing its main executable (codesign resolves `Contents/MacOS/<CFBundleExecutable>` from Info.plist), so the entitlements go on this step.
3. `codesign --verify --deep --strict --verbose=2` at the end.

`CODESIGN_IDENTITY` env var controls the identity, defaulting to `-` (ad-hoc). Set it to `"Developer ID Application: ... (TEAMID)"` for release signing. Same script works for both.

### make-dmg.sh

Plain `hdiutil create -format UDZO`. No `create-dmg` brew dependency. Refuses to package an unsigned bundle as a safety check. Output is a `.dmg` containing the `.app` plus a symlink to `/Applications` for the drag-install UX.

## End-to-end build / test

```
cmake -B build
cmake --build build
cmake --install build --prefix /tmp/pob-install-wrapper
macos/sign.sh                             # ad-hoc for local iteration
open "/tmp/pob-install-wrapper/Path of Building.app"
```

For a release build: set `CODESIGN_IDENTITY` before `sign.sh`, then run `make-dmg.sh` against the signed bundle, then notarize+staple (pipeline pending — see below).

## Upstream bugs found along the way

All documented in [UPSTREAM_NOTES.md](UPSTREAM_NOTES.md) with file/line/fix detail. Short list:

1. LuaJIT version bump — critical Apple Silicon mcode allocator fix. 100× click-latency improvement.
2. LuaJIT portfile hardcoded `x64-linux-*` build subdir.
3. lcurl `luaL_setfuncs` duplicate symbol — per-source rename replacing `--allow-multiple-definition` (which is GNU-ld-only).
4. SG `SIMPLEGRAPHIC_PLATFORM_SOURCES` clobbered on Apple (`set()` instead of `list(APPEND)`).
5. `r_font.cpp` text visibility cull uses logical window size instead of framebuffer size on HiDPI.
6. `sys_video.cpp` GLFW cursor in logical points vs. physical pixels on macOS Retina.
7. Launcher `dirname()` POSIX static-buffer aliasing.
8. `$<TARGET_RUNTIME_DLLS:>` empty on macOS — shared imported targets not captured.
9. ANGLE `liblibEGL.dylib` double-lib-prefix on macOS.
10. `UpdateCheck.lua` MakeDir POSIX-absolute-path loop bug — the hanging updater on first fresh install.
11. SG config files (`SimpleGraphic.cfg` / `imgui.ini`) write to `basePath` instead of `userPath`.

All eleven are things that belong upstream — independent of our wrapper-specific Option B architecture.

## Distribution pipeline — still pending

- Apple Developer Program reactivation (user has an inactive account — low effort)
- CI build workflow (`macos-14` arm64, builds on push/PR, uploads `.dmg` as artifact)
- `macos/notarize.sh` (`xcrun notarytool submit --wait` + `xcrun stapler staple`)
- CI release workflow (tag-triggered `mac-v*`: real sign + notarize + GitHub Release)
- Wrapper `README.md` + install docs with "unofficial port" disclaimer
- First `mac-v0.1.0` tag

## Prior art

- [PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic#98](https://github.com/PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic/pull/98) — native Linux port by `velomeister`. Does ~80% of the POSIX work we built on top of. Our SG submodule rebases our macOS changes onto this branch.
- [`hsource/pobfrontend`](https://github.com/hsource/pobfrontend) — unmaintained alternative macOS port. Uses Qt + a custom Lua frontend rather than porting SimpleGraphic. Different approach entirely; not a useful base for our work.
