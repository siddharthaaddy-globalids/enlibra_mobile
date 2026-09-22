cmake_minimum_required(VERSION 3.15)
project(llama_bridge LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Overridable so CI and IDEs can point at a checkout elsewhere. Default is
# the git submodule at the repository root.
if(NOT DEFINED LLAMA_CPP_DIR)
  set(LLAMA_CPP_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../third_party/llama.cpp")
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

add_subdirectory("${LLAMA_CPP_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/llama.cpp" EXCLUDE_FROM_ALL)

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
