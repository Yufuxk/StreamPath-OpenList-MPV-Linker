<h1 align="center">StreamPath</h1>

<p align="center">在一个 Windows 桌面应用中浏览 WebDAV 与本地媒体，并通过 MPV 播放。</p>
<p align="center">Windows 10/11 x64 · WebDAV · 本地媒体 · 影视库</p>
<p align="center"><a href="#快速开始">快速开始</a> · <a href="#影视库入门">影视库入门</a> · <a href="docs/PROJECT.md">技术与兼容说明</a></p>

<p align="center"><img src="docs/images/readme/library-home.png" alt="StreamPath 影视库主页" width="100%"></p>
<p align="center"><sub>影视库主页</sub></p>

<table>
  <tr>
    <td width="50%"><img src="docs/images/readme/series-detail.png" alt="作品详情页" width="100%"></td>
    <td width="50%"><img src="docs/images/readme/episode-list.png" alt="剧集列表" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><sub>作品详情、演职人员与关联资源</sub></td>
    <td align="center"><sub>剧集浏览、简介与观看进度</sub></td>
  </tr>
</table>

## StreamPath 能做什么

| 功能       | 说明                                                               |
| -------- | ---------------------------------------------------------------- |
| 🎬 影视库   | 整理电影与剧集，浏览海报、详情、分集和继续播放；可选 TMDB 资料匹配。                            |
| 🌐 多来源浏览 | 挂载多个 WebDAV 服务器，或添加本地文件夹；搜索并浏览媒体文件。                              |
| ▶️ 视频与音乐 | 将视频、音频和 STRM 交给外部播放器（MPV）；支持续播、自动切集、外挂字幕与字体、LRC 歌词和封面。           |
| 💿 蓝光    | 本地 ISO/BDMV 可选蓝光菜单或主标题；WebDAV ISO/BDMV 支持 Title 播放，HDMV 菜单为测试功能。 |
| 🕘 收藏与历史 | 按来源查看收藏、继续播放和最近播放记录。                                             |

界面支持简体中文、繁体中文、日文和英文。OpenList/AList 可通过 WebDAV 使用，搜索和恢复等增强功能会根据服务端能力启用。

## 快速开始

1. 从项目的 [Releases](../../releases) 页面获取并解压 Windows x64 便携版，运行 `streampath.exe`。
2. 在「设置 → 播放」选择播放器可执行文件，推荐使用 MPV。
3. 添加媒体来源：
   - **WebDAV：** 在「设置 → 服务器」创建服务器档案，再到「文件夹管理」挂载。准备服务器地址、用户名和密码；服务器允许空密码时可留空。
   - **本地文件夹：** 在「文件夹管理」添加本地目录。
4. 打开「文件夹」，进入媒体目录并点击视频、音频或 STRM 文件播放。

播放器格式支持由所配置的播放器决定。播放 OpenList 上的 STRM 文件时，建议在对应存储设置中启用「启用签名」。

## 影视库入门

1. 先按上面的步骤挂载 WebDAV 来源或添加本地目录。
2. 打开「设置 → 影视库」，添加电影或剧集所在目录。
3. 点击「手动扫描」，扫描完成后即可在影视库主页浏览作品。
4. 如需匹配 TMDB 作品资料，在影视库设置中保存并验证 TMDB **Read Access Token**；不配置 Token 也可以建立清单并播放媒体。

扫描根据文件名和目录识别资源，不读取媒体内容或探测时长、轨道等技术信息。文件名带有季集编号时，可帮助剧集正确归类。

## 支持范围与数据

- **系统：** Windows 10/11 x64。
- **播放器：** MPV 是主要支持目标；视频和音频也可按播放器参数模板使用其他外部播放器。
- **蓝光：** 支持未加密 Blu-ray。WebDAV 播放需要服务器支持随机 Range 读取和资源版本校验；DVD、AACS/BD+ 加密碟片及 BD-J 不在支持范围内。HDMV 菜单为可选测试功能。
- **便携数据：** 配置、缓存和播放记录默认保存在程序同级的 `stream_path_data/` 目录。

## 警告

请注意，本项目仅是媒体文件的管理、播放工具，不提供任何片源，开头演示内容为纯元数据



更多架构、协议和兼容细节见[技术与兼容说明](docs/PROJECT.md)。