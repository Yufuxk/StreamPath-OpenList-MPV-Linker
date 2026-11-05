# DVD 依赖源码与构建

ISO Bridge 将以下官方源码编译为静态库，不依赖用户 MPV 的 DVD 组件，也不分发或加载解密组件作为播放条件。

| 组件 | 官方归档 | SHA-256 |
| --- | --- | --- |
| libdvdread 7.1.1 | https://download.videolan.org/pub/videolan/libdvdread/7.1.1/libdvdread-7.1.1.tar.xz | `a0d47876548bec806774bbf8dbf20bb19ba139464383156b32eb8e59915b90a9` |
| libdvdnav 7.0.0 | https://download.videolan.org/pub/videolan/libdvdnav/7.0.0/libdvdnav-7.0.0.tar.xz | `a2a18f5ad36d133c74bf9106b6445806fa253b09141a46392550394b647b221e` |

归档保持原始字节。各源文件的版权与许可证声明及 `COPYING.libdvdread`／`COPYING.libdvdnav` 随本目录分发；这些库包含 GPL 代码，不能仅依据部分头文件的 LGPL 声明处理整个链接结果。

`windows/iso_bridge/dvd.cmake` 使用 FetchContent 校验本地归档并展开到构建目录，生成版本／平台配置，通过 MSVC C11 编译静态库。构建不从网络下载依赖。正式构建命令沿用 `flutter build windows --release`；可单独运行：

```powershell
cmake -S windows -B build/windows/x64
cmake --build build/windows/x64 --config Release --target streampath_iso_bridge streampath_dvd_tests
```

构建目录内应用以下兼容补丁，原始归档不改写：

- 使用 UCRT 的 inttypes／snprintf，避免旧 MSVC 兼容头覆盖标准声明；提供 Winsock timeval 并使用标准可变参数宏。
- 将流回调 seek 的字节偏移乘法显式设为 64 位，支持超过 2 GiB 的 ISO 地址。
- 将读取器固定为内置实现，禁止动态探测或加载环境中的 CSS／CPRM 解密库。
- 保留上游独立源文件及许可证，不引入 CSS／CPRM 依赖。

补丁、配置与源文件列表均位于随附的 `dvd.cmake`。完整 Bridge 源码由 StreamPath 工程中的 `windows/iso_bridge/` 提供。
