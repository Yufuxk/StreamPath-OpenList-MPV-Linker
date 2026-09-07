# libbluray 运行库来源

StreamPath ISO Bridge 固定使用 VideoLAN 官方 `libbluray 1.5.1` 源码修订
`ea3e318b89c42d2eff2ce0b9d78dc2371fbb6a67`，并静态嵌入 `libudfread 1.2.0`
修订 `139a2194525f2745b98a98e4d8fa627d07440176`。发布包中的 `bluray-4.dll`
使用 MSVC x64 Release 构建，关闭 BD-J JAR、工具、开发工具、示例、文档、Freetype、
fontconfig 与 libxml2。

- libbluray 源码：<https://code.videolan.org/videolan/libbluray/-/tree/ea3e318b89c42d2eff2ce0b9d78dc2371fbb6a67>
- libbluray 修订：`ea3e318b89c42d2eff2ce0b9d78dc2371fbb6a67`（运行时版本 `1.5.1`）
- libudfread 源码：<https://download.videolan.org/pub/videolan/libudfread/libudfread-1.2.0.tar.xz>
- libudfread 修订：`139a2194525f2745b98a98e4d8fa627d07440176`（版本 `1.2.0`）
- `bluray-4.dll` SHA-256：`2EB3F511C6EA4B2448800CFBD9C23835AB8E43100BD0EFAFE841AAC033F87C0F`

该修订包含 1.5.0 发布后上游对 CLPI EP map 索引、章节/标记范围、M2TS PES 长度及
图形段解析的越界修复。StreamPath 不携带这些上游源文件的私有分叉。

libbluray 与 libudfread 按 GNU LGPL 2.1 或后续版本授权；完整条款见同目录
`COPYING`。本运行库未链接 libaacs 或 libbdplus，也不提供 AACS/BD+ 绕过能力。
