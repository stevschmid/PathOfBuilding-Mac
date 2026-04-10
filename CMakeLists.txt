cmake_minimum_required(VERSION 3.15)

# ----- vcpkg toolchain (must come before project()) -----
# The SimpleGraphic submodule vendors vcpkg + an Apple overlay triplet
# (arm64-osx-pob) that builds ANGLE as a shared library so GLFW can dlopen
# libEGL.dylib at runtime. We auto-wire the toolchain here so cmake -B build
# Just Works without the user having to pass -DCMAKE_TOOLCHAIN_FILE.
if (APPLE AND NOT DEFINED CACHE{VCPKG_TARGET_TRIPLET})
    list(APPEND VCPKG_OVERLAY_TRIPLETS
        "${CMAKE_CURRENT_SOURCE_DIR}/SimpleGraphic/vcpkg-triplets")
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

project(PathOfBuilding-Mac C CXX)

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
set(POB_APPICON "${CMAKE_CURRENT_SOURCE_DIR}/macos/AppIcon.icns")
set_source_files_properties(${POB_APPICON} PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources")

add_executable(PathOfBuilding MACOSX_BUNDLE
    macos/launcher.c
    ${POB_APPICON}
)
target_link_libraries(PathOfBuilding PRIVATE ${CMAKE_DL_LIBS})

set_target_properties(PathOfBuilding PROPERTIES
    OUTPUT_NAME "Path of Building"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/macos/Info.plist.in"
    MACOSX_BUNDLE_BUNDLE_NAME "Path of Building"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.pathofbuildingcommunity.PathOfBuilding"
    MACOSX_BUNDLE_BUNDLE_VERSION "2.63.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "2.63.0"
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
    # Bootstrap entry that overlays src/mac_entry.lua on top of the upstream
    # Lua tree. The launcher uses this as the bundle entry script instead of
    # Launch.lua so we can install the in-app updater's manifest filter
    # before any upstream Lua code runs. The file is not in any manifest
    # (local or remote), so the updater never tracks or overwrites it.
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/macos/mac_entry.lua"
        DESTINATION "${POB_RES_DEST}/src"
    )
else()
    message(WARNING
        "POB_LUA_TREE='${POB_LUA_TREE}' has no src/Launch.lua. "
        "The .app will be built without an embedded Lua tree. Did you "
        "forget 'git submodule update --init --recursive'?")
endif()
