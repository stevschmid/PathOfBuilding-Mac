# PathOfBuilding-Mac overlay triplet for arm64-osx.
#
# Identical to the stock arm64-osx triplet (static library linkage), except:
#
#   1. `angle` is forced to build as a shared library so GLFW's EGL backend
#      can dlopen libEGL.dylib / libGLESv2.dylib at runtime. GLFW's EGL path
#      looks for these by leaf name on the dyld search path and cannot find
#      symbols inside a statically-linked-into-our-dylib ANGLE.
#
#   2. VCPKG_OSX_DEPLOYMENT_TARGET is pinned to 11.0 (Big Sur), the first
#      macOS to support Apple Silicon. All vcpkg-built objects are thus
#      compiled against the 11.0 SDK floor, matching the wrapper's own
#      CMAKE_OSX_DEPLOYMENT_TARGET. Without this, vcpkg would default to
#      the build machine's SDK version (e.g. 15.0 on Sequoia), producing
#      object files with minos=15.0 that the linker silently merges into
#      our minos=11.0 binary — a latent runtime crash on macOS <15.
#
# Lives in the PathOfBuilding-Mac wrapper (not inside SimpleGraphic) because
# these are release-policy choices the wrapper makes about what kind of
# binary it ships. Anyone embedding SG in a different wrapper should provide
# their own overlay triplet with their own deployment target / linkage
# policy; SG itself is triplet-agnostic.

set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)

set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES arm64)
set(VCPKG_OSX_DEPLOYMENT_TARGET "11.0")

if(PORT STREQUAL "angle")
    set(VCPKG_LIBRARY_LINKAGE dynamic)
endif()
