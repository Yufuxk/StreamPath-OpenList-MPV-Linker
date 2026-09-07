cmake_minimum_required(VERSION 3.14)
enable_language(C)

set(ISO_BRIDGE_THIRD_PARTY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libbluray")
set(ISO_BRIDGE_DLL "${ISO_BRIDGE_THIRD_PARTY_DIR}/bin/bluray-4.dll")

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "StreamPath ISO Bridge only supports Windows x64")
endif()
if(NOT EXISTS "${ISO_BRIDGE_DLL}")
  message(FATAL_ERROR "Missing fixed libbluray runtime: ${ISO_BRIDGE_DLL}")
endif()

add_library(streampath_iso_bridge_core STATIC
  "bridge_core.cpp"
  "bridge_core.h"
  "iso_structure_cache.cpp"
  "iso_structure_cache.h"
  "remote_disc_provider.cpp"
  "remote_disc_provider.h"
  "remote_disc_endpoint.cpp"
  "remote_disc_endpoint.h"
)
target_compile_features(streampath_iso_bridge_core PUBLIC cxx_std_17)
target_include_directories(streampath_iso_bridge_core PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_options(streampath_iso_bridge_core PRIVATE /W4 /WX /EHsc /utf-8)

include("winfsp.cmake")
add_executable(streampath_iso_bridge WIN32 "main.cpp")
target_compile_features(streampath_iso_bridge PRIVATE cxx_std_17)
target_compile_options(streampath_iso_bridge PRIVATE /W4 /WX /EHsc /utf-8)
target_compile_definitions(streampath_iso_bridge PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  UNICODE
  _UNICODE
)
target_include_directories(streampath_iso_bridge PRIVATE
  "${ISO_BRIDGE_THIRD_PARTY_DIR}/include"
)
target_link_libraries(streampath_iso_bridge PRIVATE
  streampath_iso_bridge_core
  streampath_winfsp
  bcrypt.lib
  advapi32.lib
  shell32.lib
  shlwapi.lib
  winhttp.lib
  ws2_32.lib
)
set_target_properties(streampath_iso_bridge PROPERTIES
  OUTPUT_NAME "streampath_iso_bridge"
)

add_executable(streampath_iso_bridge_tests "bridge_core_tests.cpp")
target_compile_features(streampath_iso_bridge_tests PRIVATE cxx_std_17)
target_compile_options(streampath_iso_bridge_tests PRIVATE /W4 /WX /EHsc /utf-8)
target_link_libraries(streampath_iso_bridge_tests PRIVATE
  streampath_iso_bridge_core
  bcrypt.lib
)

add_executable(streampath_iso_bridge_network_tests "range_reader_tests.cpp"
  "remote_mpv_adapter_test_api.c")
target_compile_features(streampath_iso_bridge_network_tests PRIVATE cxx_std_17)
target_compile_options(streampath_iso_bridge_network_tests PRIVATE
  /W4 /WX /EHsc /utf-8 /wd4505
)
target_compile_definitions(streampath_iso_bridge_network_tests PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  UNICODE
  _UNICODE
  STREAMPATH_ISO_BRIDGE_TESTING
)
target_include_directories(streampath_iso_bridge_network_tests PRIVATE
  "${ISO_BRIDGE_THIRD_PARTY_DIR}/include"
)
target_link_libraries(streampath_iso_bridge_network_tests PRIVATE
  streampath_iso_bridge_core
  streampath_winfsp
  bcrypt.lib
  advapi32.lib
  shell32.lib
  shlwapi.lib
  winhttp.lib
  ws2_32.lib
)

install(TARGETS streampath_iso_bridge
  RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime
)
install(FILES
  "${ISO_BRIDGE_DLL}"
  "${ISO_BRIDGE_THIRD_PARTY_DIR}/COPYING"
  "${ISO_BRIDGE_THIRD_PARTY_DIR}/SOURCE.md"
  DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime
)
