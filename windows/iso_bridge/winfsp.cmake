# 固定 SDK 只用于编译；运行时使用系统已安装的签名 WinFsp。
set(WINFSP_ARCHIVE "${CMAKE_BINARY_DIR}/winfsp-v2.1.zip")
set(WINFSP_SOURCE "${CMAKE_BINARY_DIR}/winfsp-sdk/winfsp-2.1")
if(NOT EXISTS "${WINFSP_SOURCE}/inc/winfsp/winfsp.h")
  file(DOWNLOAD "https://github.com/winfsp/winfsp/archive/refs/tags/v2.1.zip"
    "${WINFSP_ARCHIVE}"
    EXPECTED_HASH SHA256=7b51f3c64fc5596eab315c8812f8b13e96d6830deef66e30df2019dafd3e0dd4
    TLS_VERIFY ON)
  file(ARCHIVE_EXTRACT INPUT "${WINFSP_ARCHIVE}"
    DESTINATION "${CMAKE_BINARY_DIR}/winfsp-sdk")
endif()
add_library(streampath_winfsp STATIC "winfsp_disc.cpp")
target_compile_features(streampath_winfsp PUBLIC cxx_std_17)
target_compile_definitions(streampath_winfsp PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN UNICODE _UNICODE)
target_compile_options(streampath_winfsp PRIVATE /W4 /WX /EHsc /utf-8)
target_include_directories(streampath_winfsp SYSTEM PRIVATE "${WINFSP_SOURCE}/inc")
target_link_libraries(streampath_winfsp PUBLIC streampath_iso_bridge_core advapi32)
set(WINFSP_INSTALLER "${CMAKE_BINARY_DIR}/winfsp-2.1.25156.msi")
if(NOT EXISTS "${WINFSP_INSTALLER}")
  file(DOWNLOAD "https://github.com/winfsp/winfsp/releases/download/v2.1/winfsp-2.1.25156.msi"
    "${WINFSP_INSTALLER}"
    EXPECTED_HASH SHA256=073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a
    TLS_VERIFY ON)
endif()
install(FILES "${WINFSP_INSTALLER}" "${WINFSP_SOURCE}/License.txt"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/install_winfsp.ps1"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/winfsp" COMPONENT Runtime)
