cmake_minimum_required(VERSION 3.15)
include("${CMAKE_CURRENT_SOURCE_DIR}/../cxx/quickjs.cmake")

set(PROJECT_NAME "flutter_qjs_next")
project(${PROJECT_NAME} LANGUAGES CXX)
add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/utf-8>")

set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

add_library(${PLUGIN_NAME} SHARED
  "flutter_qjs_plugin.cpp"
  "${CXX_LIB_DIR}/ffi.cpp"
)
apply_standard_settings(${PLUGIN_NAME})
if(MSVC)
  # quickjs.h builds JSValues with compound literals (JS_MKVAL). MSVC's C++
  # front end accepts the designated initializers inside them only from C++20
  # on, and still reports the `(type){...}` syntax itself as non-standard
  # (C4576). C4244 is upstream's int64_t -> int32_t narrowing in that header.
  target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_20)
  target_compile_options(${PLUGIN_NAME} PRIVATE /wd4576 /wd4244)
endif()
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin quickjs)

# List of absolute paths to libraries that should be bundled with the plugin
set(flutter_qjs_next_bundled_libraries
  ""
  PARENT_SCOPE
)
