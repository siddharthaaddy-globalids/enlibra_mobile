cmake_minimum_required(VERSION 3.15)
project(llama_bridge_linux)
add_subdirectory(../src "${CMAKE_CURRENT_BINARY_DIR}/shared")
set(llama_bridge_bundled_libraries
  "$<TARGET_FILE:llama_bridge>"
  PARENT_SCOPE
)
