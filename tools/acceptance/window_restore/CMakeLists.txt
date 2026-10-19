cmake_minimum_required(VERSION 3.14)
project(window_restore_tests LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
get_filename_component(PROJECT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
add_executable(window_restore_tests
  window_restore_tests.cpp
  "${PROJECT_ROOT}/windows/runner/win32_window.cpp")
target_compile_definitions(window_restore_tests PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(window_restore_tests PRIVATE /utf-8)
target_include_directories(window_restore_tests PRIVATE
  "${PROJECT_ROOT}/windows/runner"
  "${PROJECT_ROOT}/windows/flutter/ephemeral")
target_link_libraries(window_restore_tests PRIVATE
  "${PROJECT_ROOT}/windows/flutter/ephemeral/flutter_windows.dll.lib"
  dwmapi comctl32 advapi32)
add_custom_command(TARGET window_restore_tests POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_if_different
  "${PROJECT_ROOT}/windows/flutter/ephemeral/flutter_windows.dll"
  "$<TARGET_FILE_DIR:window_restore_tests>")
enable_testing()
add_test(NAME window_restore_tests COMMAND window_restore_tests)
