cmake_minimum_required(VERSION 3.15)
project(llama_bridge LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Overridable so CI and IDEs can point at a checkout elsewhere. Default is
# the git submodule at the repository root.
#
# Finding it is not a fixed relative path, because the Windows build reaches
# this file through a plugin symlink under
# windows/flutter/ephemeral/.plugin_symlinks/, where CMAKE_CURRENT_LIST_DIR
# is nowhere near the repository root. Android and Linux use the real path.
# So: try several anchors, resolving symlinks, and walk up from each.
if(NOT DEFINED LLAMA_CPP_DIR)
  get_filename_component(_lb_real "${CMAKE_CURRENT_LIST_DIR}" REALPATH)
  foreach(_lb_anchor "${_lb_real}" "${CMAKE_CURRENT_LIST_DIR}" "${CMAKE_SOURCE_DIR}")
    set(_lb_dir "${_lb_anchor}")
    foreach(_lb_up RANGE 6)
      if(EXISTS "${_lb_dir}/third_party/llama.cpp/include/llama.h")
        set(LLAMA_CPP_DIR "${_lb_dir}/third_party/llama.cpp")
        break()
      endif()
      get_filename_component(_lb_dir "${_lb_dir}" DIRECTORY)
    endforeach()
    if(DEFINED LLAMA_CPP_DIR)
      break()
    endif()
  endforeach()
endif()

if(NOT DEFINED LLAMA_CPP_DIR)
  message(FATAL_ERROR
    "Could not locate third_party/llama.cpp by walking up from "
    "${CMAKE_CURRENT_LIST_DIR}. Run: git submodule update --init --recursive "
    "(or pass -DLLAMA_CPP_DIR=/path/to/llama.cpp)")
endif()

get_filename_component(LLAMA_CPP_DIR "${LLAMA_CPP_DIR}" ABSOLUTE)

if(NOT EXISTS "${LLAMA_CPP_DIR}/include/llama.h")
  message(FATAL_ERROR
    "llama.cpp not found at ${LLAMA_CPP_DIR}. "
    "Run: git submodule update --init --recursive")
endif()

# We link llama statically into our own shared library, so nothing outside
# needs to know llama.cpp exists. This keeps the app to one native artifact
# per platform instead of a chain of .so files that Android must load in
# the right order.
set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS      OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES   OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS      OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON     OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL             OFF CACHE BOOL "" FORCE)

# GGML_NATIVE bakes -march=native into the build. That is correct for a
# desktop binary and catastrophic for a shipped app: it produces code tuned
# to whatever machine happened to run CI, which then SIGILLs on user
# devices. Always off here.
set(GGML_NATIVE            OFF CACHE BOOL "" FORCE)

if(ANDROID)
  set(GGML_OPENMP OFF CACHE BOOL "" FORCE)  # not in the NDK sysroot
  if(ANDROID_ABI STREQUAL "arm64-v8a")
    # armv8.2 dotprod + i8mm is roughly a 2x prompt-processing speedup on
    # modern SoCs and is present on essentially every 64-bit device with
    # enough RAM to run these models.
    #
    # Guarded by ABI because x86_64 is also built, for emulators: forcing
    # an ARM -march onto an x86 target fails the compiler outright.
    set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+i8mm" CACHE STRING "" FORCE)
  endif()
elseif(APPLE)
  set(GGML_METAL ON CACHE BOOL "" FORCE)
  # Without this, Metal looks for default.metallib next to the binary,
  # which does not exist inside an app bundle laid out by Flutter.
  set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
endif()

# Deliberately NOT EXCLUDE_FROM_ALL. Under the Visual Studio generator that
# suppresses generation of the ggml .vcxproj files while llama.vcxproj still
# references them, and MSBuild fails with MSB3202. Ninja tolerates it, so
# this only ever breaks the Windows build. Tests, examples, tools and the
# server are already off above, so including all targets costs us nothing
# beyond llama and ggml, which we link anyway.
#
# But keeping install() active brings its own problem: llama.cpp installs its
# libraries and headers unconditionally, while Flutter sets
# CMAKE_INSTALL_PREFIX to a generator expression ($<TARGET_FILE_DIR:...>).
# Those destinations are computed at generate time, so the literal genex text
# ends up in the path and the install step dies with
#   file cannot create directory: .../$<TARGET_FILE_DIR:enlibra_mobile>/lib
#
# We want none of llama.cpp's install rules -- Flutter bundles our DLL via
# llama_bridge_bundled_libraries below. So override install() with a macro
# that swallows calls only while the flag is set. The flag is a directory
# variable, so it is visible to llama.cpp (added beneath us) and absent in
# Flutter's own scope, whose install() rules must keep working. Overriding
# exactly once matters: a second override would make _install resolve to the
# first override rather than the built-in.
macro(install)
  if(NOT _LB_SUPPRESS_INSTALL)
    _install(${ARGV})
  endif()
endmacro()

set(_LB_SUPPRESS_INSTALL TRUE)
add_subdirectory("${LLAMA_CPP_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/llama.cpp")
set(_LB_SUPPRESS_INSTALL FALSE)

add_library(llama_bridge SHARED llama_bridge.cpp)

target_include_directories(llama_bridge PRIVATE "${CMAKE_CURRENT_LIST_DIR}")
target_link_libraries(llama_bridge PRIVATE llama ggml)

set_target_properties(llama_bridge PROPERTIES
  PUBLIC_HEADER llama_bridge.h
  OUTPUT_NAME "llama_bridge"
  # Everything is exported explicitly with LB_EXPORT, so hide the rest.
  # Keeps llama.cpp's symbols out of the dynamic table.
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
)

target_compile_definitions(llama_bridge PUBLIC DART_SHARED_LIB)

if(ANDROID)
  # Flutter's Android build does not strip plugin libraries, and llama.cpp
  # with debug symbols adds tens of megabytes to the APK.
  target_link_options(llama_bridge PRIVATE "-Wl,-z,max-page-size=16384")
endif()
