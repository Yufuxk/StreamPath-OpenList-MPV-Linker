<h1 align="center">StreamPath</h1>

<p align="center">Browse WebDAV and local media in a Windows desktop app, and play them with MPV.</p>
<p align="center">Windows 10/11 x64 · WebDAV · Local Media · Media Library</p>
<p align="center"><a href="#quick-start">Quick Start</a> · <a href="#getting-started-with-the-media-library">Media Library Guide</a> · <a href="docs/PROJECT.md">Technical & Compatibility Notes</a></p>

<p align="center"><img src="docs/images/readme/library-home.png" alt="StreamPath Media Library Home" width="100%"></p>
<p align="center"><sub>Media Library Home</sub></p>

<table>
  <tr>
    <td width="50%"><img src="docs/images/readme/series-detail.png" alt="Title Details" width="100%"></td>
    <td width="50%"><img src="docs/images/readme/episode-list.png" alt="Episode List" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><sub>Title details, cast and crew, and related resources</sub></td>
    <td align="center"><sub>Episode browsing, descriptions, and watch progress</sub></td>
  </tr>
</table>

## What StreamPath Can Do

| Feature | Description |
| --- | --- |
| 🎬 Media Library | Organize movies and TV series, browse posters, details, episodes, and continue watching; optional TMDB metadata matching is supported. |
| 🌐 Multi-Source Browsing | Mount multiple WebDAV servers or add local folders; search and browse media files. |
| ▶️ Video & Music | Open video, audio, and STRM files in an external player (MPV); supports resume playback, automatic episode switching, external subtitles and fonts, LRC lyrics, and cover art. |
| 💿 Blu-ray | Local ISO/BDMV supports either Blu-ray menus or main-title playback; WebDAV ISO/BDMV supports title playback, while HDMV menus are an experimental feature. |
| 🕘 Favorites & History | View favorites, continue-watching items, and recent playback history by source. |

The interface supports Simplified Chinese, Traditional Chinese, Japanese, and English. OpenList/AList can be used via WebDAV, while enhanced features such as search and resume support are enabled depending on server capabilities.

## Quick Start

1. Download and extract the Windows x64 portable build from the project's [Releases](../../releases) page, then run `streampath.exe`.
2. Go to **Settings → Playback** and select the player executable. MPV is recommended.
3. Add a media source:
   - **WebDAV:** Create a server profile under **Settings → Servers**, then mount it in **Folder Management**. Prepare the server address, username, and password; leave the password blank if the server allows an empty password.
   - **Local Folder:** Add a local directory in **Folder Management**.
4. Open **Folders**, navigate to a media directory, and click a video, audio, or STRM file to play it.

Supported media formats are determined by the configured player. When playing STRM files hosted on OpenList, it is recommended to enable **Enable Signing** in the corresponding storage settings.

## Getting Started with the Media Library

1. First, mount a WebDAV source or add a local directory as described above.
2. Open **Settings → Media Library** and add the directories containing your movies or TV series.
3. Click **Manual Scan**. Once the scan is complete, the titles will appear on the Media Library home page.
4. To match titles with TMDB metadata, save and verify a TMDB **Read Access Token** in the Media Library settings. You can still build the library and play media without configuring a token.

Scanning identifies media based on file and directory names. It does not read media contents or probe technical information such as duration or tracks. Including season and episode numbers in filenames helps TV episodes be categorized correctly.

## Support & Data

- **System:** Windows 10/11 x64.
- **Player:** MPV is the primary supported player; video and audio can also be opened with other external players using configurable player argument templates.
- **Blu-ray:** Unencrypted Blu-ray is supported. WebDAV playback requires the server to support random Range reads and resource version validation. DVD, AACS/BD+ encrypted discs, and BD-J are not supported. HDMV menus are an optional experimental feature.
- **Portable Data:** Configuration, cache, and playback history are stored by default in the `stream_path_data/` directory next to the application executable.

## Warning

Please note that this project is only a media file management and playback tool and does not provide any media sources. The demo content shown at the beginning consists of metadata only.

For more details about the architecture, protocols, and compatibility, see [Technical & Compatibility Notes](docs/PROJECT.md).
