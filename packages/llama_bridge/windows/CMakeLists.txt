cmake_minimum_required(VERSION 3.15)
project(llama_bridge_windows)
add_subdirectory(../src "${CMAKE_CURRENT_BINARY_DIR}/shared")
# Flutter's Windows build copies anything listed here next to the exe.
set(llama_bridge_bundled_libraries
  "$<TARGET_FILE:llama_bridge>"
  PARENT_SCOPE
)
