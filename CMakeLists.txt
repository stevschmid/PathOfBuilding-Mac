cmake_minimum_required(VERSION 3.15)

# ----- vcpkg toolchain (must come before project()) -----
# The SimpleGraphic submodule vendors vcpkg. Our overlay triplet
# (arm64-osx-pob) lives in this wrapper's own vcpkg-triplets/ directory
# and controls wrapper-specific release policy: ANGLE is forced shared so
# GLFW can dlopen libEGL.dylib, and VCPKG_OSX_DEPLOYMENT_TARGET is pinned
# to 11.0 to match the wrapper's CMAKE_OSX_DEPLOYMENT_TARGET. We auto-wire
# the toolchain here so `cmake -B build` Just Works without the user
# having to pass -DCMAKE_TOOLCHAIN_FILE.
if (APPLE AND NOT DEFINED CACHE{VCPKG_TARGET_TRIPLET})
    list(APPEND VCPKG_OVERLAY_TRIPLETS
        "${CMAKE_CURRENT_SOURCE_DIR}/vcpkg-triplets")
    set(VCPKG_OVERLAY_TRIPLETS "${VCPKG_OVERLAY_TRIPLETS}" CACHE STRING "")
    set(VCPKG_TARGET_TRIPLET "arm64-osx-pob" CACHE STRING "")
    set(VCPKG_HOST_TRIPLET "arm64-osx-pob" CACHE STRING "")
endif()

if (NOT DEFINED CMAKE_TOOLCHAIN_FILE)
    set(CMAKE_TOOLCHAIN_FILE
        "${CMAKE_CURRENT_SOURCE_DIR}/SimpleGraphic/vcpkg/scripts/buildsystems/vcpkg.cmake"
        CACHE FILEPATH "")
endif()

# vcpkg manifest (vcpkg.json + vcpkg-configuration.json) lives inside the
# SimpleGraphic submodule. Point vcpkg's manifest discovery at that directory
# so it picks up the engine's dependency list.
if (NOT DEFINED VCPKG_MANIFEST_DIR)
    set(VCPKG_MANIFEST_DIR
        "${CMAKE_CURRENT_SOURCE_DIR}/SimpleGraphic"
        CACHE PATH "")
endif()

# Minimum macOS version the shipped binary will load on. 11.0 (Big Sur) is
# the first macOS to support Apple Silicon, and this wrapper is arm64-only,
# so lower targets are meaningless. Must be set before the first project()
# call because CMake reads it during Apple toolchain detection. Overridable
# via -DCMAKE_OSX_DEPLOYMENT_TARGET at configure time.
if (NOT DEFINED CACHE{CMAKE_OSX_DEPLOYMENT_TARGET})
    set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING
        "Minimum macOS version the .app bundle runs on")
endif()

project(PathOfBuilding-Mac C CXX)

# launcher.cpp leans on <filesystem> and <optional>.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if (NOT APPLE)
    message(FATAL_ERROR
        "PathOfBuilding-Mac is the macOS distribution wrapper for PoB. "
        "To build SimpleGraphic on Linux/Windows, build the SimpleGraphic "
        "submodule directly, not this top-level project.")
endif()

# ----- Bundle layout -----
# These override the engine's defaults (which are flat for standalone use)
# so SimpleGraphic's install rules deposit dylibs and helper modules directly
# into the .app bundle. The engine's CMakeLists reads POB_BIN_DEST/POB_RES_DEST
# from the cache before its own conditional defaults kick in.
set(POB_BIN_DEST "Path of Building.app/Contents/MacOS"
    CACHE STRING "Where SimpleGraphic dylibs land inside the bundle" FORCE)
set(POB_RES_DEST "Path of Building.app/Contents/Resources"
    CACHE STRING "Where bundled resources land inside the bundle" FORCE)

# Path to the PoB Lua tree that gets bundled into Contents/Resources.
# Defaults to the PathOfBuilding submodule but can be overridden for local
# dev against a sibling checkout.
set(POB_LUA_TREE "${CMAKE_CURRENT_SOURCE_DIR}/PathOfBuilding"
    CACHE PATH "Path to the PathOfBuilding main repo (Lua tree bundled into the .app)")

# ----- Build the engine -----
# SimpleGraphic produces libSimpleGraphic.dylib + lcurl/lzip/lua-utf8/socket
# helper modules. Its install rules use POB_BIN_DEST (set above) so everything
# lands in Contents/MacOS.
add_subdirectory(SimpleGraphic)

# ----- Bundle target -----
# Bump in lockstep with the pinned PathOfBuilding submodule. Drives both
# Info.plist and the App Support refresh marker.
set(POB_BUNDLE_VERSION "2.63.0")

set(POB_APPICON "${CMAKE_CURRENT_SOURCE_DIR}/macos/AppIcon.icns")
set_source_files_properties(${POB_APPICON} PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources")

add_executable(PathOfBuilding MACOSX_BUNDLE
    macos/launcher.cpp
    ${POB_APPICON}
)
target_link_libraries(PathOfBuilding PRIVATE ${CMAKE_DL_LIBS})

target_compile_definitions(PathOfBuilding PRIVATE
    POB_BUNDLE_VERSION_STRING="${POB_BUNDLE_VERSION}"
)

set_target_properties(PathOfBuilding PROPERTIES
    OUTPUT_NAME "Path of Building"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/macos/Info.plist.in"
    MACOSX_BUNDLE_BUNDLE_NAME "Path of Building"
    MACOSX_BUNDLE_GUI_IDENTIFIER "ch.spidy.PathOfBuildingMac"
    MACOSX_BUNDLE_BUNDLE_VERSION "${POB_BUNDLE_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${POB_BUNDLE_VERSION}"
    MACOSX_BUNDLE_ICON_FILE "AppIcon"
)

install(TARGETS PathOfBuilding
    BUNDLE DESTINATION "."
    RUNTIME DESTINATION "${POB_BIN_DEST}"
)

# ----- Bundle the PoB Lua tree -----
if (EXISTS "${POB_LUA_TREE}/src/Launch.lua")
    install(DIRECTORY "${POB_LUA_TREE}/src"
        DESTINATION "${POB_RES_DEST}"
        PATTERN ".git*" EXCLUDE
        PATTERN "Update" EXCLUDE
    )
    install(DIRECTORY "${POB_LUA_TREE}/runtime/lua"
        DESTINATION "${POB_RES_DEST}"
    )
    install(DIRECTORY "${POB_LUA_TREE}/runtime/SimpleGraphic"
        DESTINATION "${POB_RES_DEST}"
        PATTERN "*.cfg" EXCLUDE
    )

    # Top-level PoB data files (changelog/help/LICENSE) live at the repo
    # root in the git tree but PoB's installed-mode Lua code reads them
    # relative to scriptPath (= src/) — see Modules/Main.lua where
    # `launch.devMode and "../changelog.txt" or "changelog.txt"` picks the
    # dev-vs-installed path. The Windows installer moves these files into
    # src/ as a packaging step; we mirror that here. Without this, PoB's
    # in-app updater reports "Update available" on first launch because
    # UpdateCheck.lua sees them as missing and triggers a download.
    install(FILES
        "${POB_LUA_TREE}/changelog.txt"
        "${POB_LUA_TREE}/help.txt"
        "${POB_LUA_TREE}/LICENSE.md"
        DESTINATION "${POB_RES_DEST}/src"
    )
    # Bootstrap entry that overlays src/mac_entry.lua on top of the upstream
    # Lua tree. The launcher uses this as the bundle entry script instead of
    # Launch.lua so we can install the in-app updater's manifest filter
    # before any upstream Lua code runs. The file is not in any manifest
    # (local or remote), so the updater never tracks or overwrites it.
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/macos/mac_entry.lua"
        DESTINATION "${POB_RES_DEST}/src"
    )

    # Generate a stripped manifest.xml from upstream's at configure time.
    # PoB's in-app updater needs this file to:
    #   (1) know what version is installed (drives the changelog popup),
    #   (2) know which files to track locally (drives the diff against the
    #       remote manifest).
    # We strip Windows-only entries (runtime="win32") so the updater never
    # tries to download DLLs/exe, and we add branch + platform attributes
    # to <Version> so Launch.lua doesn't engage dev mode (which would
    # disable updates entirely). The mac_entry.lua filter strips the same
    # things at runtime; doing it at install time too just makes the
    # initial state correct without needing the in-app updater to apply a
    # round-trip first.
    if (EXISTS "${POB_LUA_TREE}/manifest.xml")
        file(READ "${POB_LUA_TREE}/manifest.xml" _pob_manifest)
        string(REGEX REPLACE "[^\n]*runtime=\"win32\"[^\n]*\n" ""
            _pob_manifest "${_pob_manifest}")
        string(REGEX REPLACE
            "<Version (number=\"[^\"]*\") />"
            "<Version \\1 branch=\"master\" platform=\"macos\" />"
            _pob_manifest "${_pob_manifest}")
        file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/manifest.xml" "${_pob_manifest}")
        # Re-run configure when upstream's manifest changes (e.g. after a
        # PathOfBuilding submodule bump) so the generated copy stays in sync.
        set_property(DIRECTORY APPEND PROPERTY
            CMAKE_CONFIGURE_DEPENDS "${POB_LUA_TREE}/manifest.xml")
        install(FILES "${CMAKE_CURRENT_BINARY_DIR}/manifest.xml"
            DESTINATION "${POB_RES_DEST}/src"
        )
    endif()
else()
    message(WARNING
        "POB_LUA_TREE='${POB_LUA_TREE}' has no src/Launch.lua. "
        "The .app will be built without an embedded Lua tree. Did you "
        "forget 'git submodule update --init --recursive'?")
endif()
