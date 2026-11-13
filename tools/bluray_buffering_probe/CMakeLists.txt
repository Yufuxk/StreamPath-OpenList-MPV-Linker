cmake_minimum_required(VERSION 3.16)
project(bluray_buffering_probe LANGUAGES CXX)
find_package(Threads REQUIRED)
add_executable(bluray_buffering_probe
  probe.cpp
  ../../windows/iso_bridge/bridge_core.cpp
)
target_include_directories(bluray_buffering_probe PRIVATE ../../windows/iso_bridge)
target_compile_features(bluray_buffering_probe PRIVATE cxx_std_17)
target_link_libraries(bluray_buffering_probe PRIVATE Threads::Threads)
if(MSVC)
  target_compile_options(bluray_buffering_probe PRIVATE /W4 /WX /EHsc /utf-8)
endif()
if(WIN32)
  add_executable(bridge_core_regression
    ../../windows/iso_bridge/bridge_core_tests.cpp
    ../../windows/iso_bridge/bridge_core.cpp
    ../../windows/iso_bridge/iso_structure_cache.cpp
    ../../windows/iso_bridge/remote_disc_provider.cpp
    ../../windows/iso_bridge/remote_disc_endpoint.cpp
  )
  target_include_directories(bridge_core_regression PRIVATE ../../windows/iso_bridge)
  target_compile_features(bridge_core_regression PRIVATE cxx_std_17)
  target_compile_options(bridge_core_regression PRIVATE /W4 /WX /EHsc /utf-8)
  target_link_libraries(bridge_core_regression PRIVATE bcrypt.lib Threads::Threads)
endif()
