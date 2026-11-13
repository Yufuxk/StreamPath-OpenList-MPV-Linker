<h1 align="center">StreamPath</h1>

<p align="center"><a href="README.md">简体中文</a> · English</p>

<p align="center">Browse network storage, local media, and media servers on Windows, with playback powered by MPV.</p>
<p align="center">Windows 10/11 x64 · WebDAV / SMB / FTP / NFS · Jellyfin / Emby · Media Library</p>
<p align="center"><a href="#quick-start">Quick Start</a> · <a href="#getting-started-with-the-media-library">Media Library Guide</a> · <a href="docs/PROJECT.md">Technical Details & Compatibility</a></p>

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

<p align="center"><img src="docs/images/readme/movie-showcase.png" alt="Movie Showcase" width="100%"></p>
<p align="center"><sub>Movie Showcase</sub></p>

## What Can StreamPath Do?

| Feature | Description |
| --- | --- |
| 🎬 Media Library | Browse movies, TV series, collections, daily picks, title details, and episodes. Supports TMDB and local NFO metadata. |
| 🌐 Multiple Sources | Browse WebDAV, SMB, FTP/FTPS, NFS, and local folders, or connect to Jellyfin and Emby. |
| ▶️ Video & Music | Play video, audio, and STRM files with MPV. Supports resume playback, automatic episode transitions, external subtitles and fonts, lyrics, and cover art. |
| 💿 Discs | Blu-ray ISO/BDMV supports main-title playback and optional menus. DVD ISO supports title playlists for local, network, and fully cached sources. |
| 🕘 Favorites & History | Browse favorites, resume playback, and recently played items by source. Import and export selected categories of metadata and personal states. |

Right-click a title, season, or resource cover and select **Edit Metadata...** to edit text, choose scraped images, or import local images or image URLs. Customizations are saved locally and automatically protected from being overwritten. Individual fields can be restored to their source values. By default, editing a resource affects only the current version.

The interface supports Simplified Chinese, Traditional Chinese, Japanese, and English. OpenList/AList can be accessed through WebDAV. Features such as search and recovery depend on server capabilities.

## Quick Start

1. Download the Windows x64 installer (`.setup.exe`) from the project's [Releases](../../releases) page and follow the setup wizard. Alternatively, extract the portable package (`.portable.zip`) and run `streampath.exe`.
2. Go to **Settings → Playback** and select your player executable. MPV is recommended.
3. Add a media source:
   - **WebDAV:** Click Add under **Folders → Network Storage**, select WebDAV as the source type, and enter a name, server address, and account credentials. You can optionally specify a default directory. Leave the password blank if the server allows it.
   - **Local Folders:** Add a directory under **Folders → Local Folders**.
   - **SMB, FTP/FTPS, NFS:** Select the corresponding protocol in the same **Add Network Storage** dialog and enter the protocol address and credentials. Configure the SMB domain, NFS version, and UID/GID as needed.
   - **Jellyfin, Emby:** Add a server and account under **Folders → Media Servers**, then select the server at the top of the media library to browse titles and play available versions.
4. Open **Folders**, navigate to your media directory, and click a video, audio, or STRM file to play it.

Supported media formats depend on the configured player. When playing STRM files hosted on OpenList, enabling **Enable Signing** in the corresponding storage settings is recommended.

Under **Settings → Playback → External Player**, enter one launch argument per line. The `{url}`, `{subfile}`, and `{start}` placeholders are supported. By default, arguments are injected for every playback session. Disable **Inject All** to inject arguments selectively for anime, movies, or TV series—for example, enabling Anime4K upscaling only for anime. Classification is based on media library metadata; playback without metadata receives no category-specific arguments. For syntax, examples, and troubleshooting, see [Category-Based Injection of External Player Launch Arguments](docs/外部播放器启动参数分类注入.md).

On the same settings page, click **Manage Saved MPV Configuration** to edit local options, profiles, keyboard shortcuts, plugin configuration, and source files, as well as to enable or disable scripts and reorder shader references. Each completed change is saved automatically without altering unrelated original content. **Change History** provides diffs and restoration options. Changes take effect the next time MPV starts.

## Installation & Software Updates

The installed version uses `%LOCALAPPDATA%\Programs\StreamPath` as its default installation directory. It is available only to the current Windows user and does not require administrator privileges. You can change the installation directory or create a desktop shortcut. Uninstalling does not delete user data.

Go to **Settings → General → Software Updates** to view the version or check for updates manually. The application also checks official Releases on startup and downloads a compatible installer or portable package in the background. Once the download is complete, click **Restart to Update**. Finish playback, scanning, and import tasks first; the application saves its state and restarts.

Updates preserve the current copy's data. Installed and portable versions use separate data directories, and data from other copies is not migrated automatically. Older versions must first be upgraded manually. Automatic updates are unavailable if a Release lacks the required manifest or a matching package.

## Getting Started with the Media Library

1. Add media sources first. **Main Media Library** aggregates enabled directories. You can also select Jellyfin or Emby from the dropdown at the top.
2. Open **Folders → Media Library** and add directories containing movies or TV series.
   Use **Edit Media Directory** to change the name, source, type, and scanning settings. Local and WebDAV directories also support metadata reading, write-back, and read-only settings.
3. Click **Manual Scan** to populate the library, then browse your titles.
4. To retrieve TMDB metadata, save and verify a **Read Access Token** in the media library settings. You can still scan and play content without a token.

The top of **Folders → Media Library** shows catalog statistics for enabled directories: **TV Episodes** counts individual episode entries; **TV Series** counts distinct series; **Movies** includes regular movies, ISO, and BDMV; and **Other** counts unrecognized entries. Multiple versions of the same movie or episode are counted separately, whereas a series is counted only once. Disabled directories and missing resources are excluded. Statistics update automatically after scans or changes to directory enablement.

The media library poster wall can be sorted by title, date added, year, or TMDB rating. Use the control next to the sort field to switch between ascending and descending order. Titles without a year or rating are placed last when sorting by those fields.

The media library identifies content from filenames and directory structures. It does not read media file contents or probe technical details such as duration and tracks. Including season and episode numbers in filenames improves classification accuracy.

**Special Episodes** for TV series and **Bonus Videos** for movies support category badges and filters. Under **Settings → Media Library → Special Features Category Management**, you can edit category names and recognition aliases or add custom categories. Use **Change Special Feature Type** in a resource's right-click menu to correct its category manually, or select **Auto Detect** to restore automatic classification. SCAN/CD-type directories are excluded from video resource classification.

For category descriptions, instructions, and naming examples, see the [Special Features Classification Guide](docs/特典分类系统使用指南.md).

Under **Settings → Media Library → Media Library Preferences**, enter comma-separated names in **Excluded Folder Names** and save. Fuzzy mode matches keywords, while exact mode matches full folder names; both are case-sensitive. Matching folders and their subfolders are skipped during scanning and removed from the catalog on subsequent scans or metadata scraping. Clear the names and scan again to restore them.

The toggle on each directory card enables or disables that media library. When disabled, its associated titles, collections, and source entries are hidden and excluded from playback, episode transitions, and scheduled scanning. Personal records are preserved and restored when the directory is re-enabled. Automatic scans run once per day by default, with a minimum interval of six hours, and only while the application is idle. You can also scan a specified subdirectory.

**Full-Speed Scan/Scrape** on a directory card supports full scans, incremental scans, scans of selected directories, and standalone metadata scraping. **Scan Multiple Sources** also offers a full-speed mode. This works with local, WebDAV, SMB, FTP, and NFS sources. Before each run, you must acknowledge potential cloud-storage account restrictions and resource-usage risks. It cannot start while playback or another scan/scrape task is active. While it is running, only the option to close the application remains available. Closing the application saves progress; on the next launch, you can resume, defer, or discard the task, or resume a paused task from the media library management page. Jellyfin/Emby continue to use server synchronization.

**Local Metadata Mode** prioritizes existing NFO files and posters and suspends automatic online matching. Network mode falls back to local metadata if online information is unavailable. Write-back is disabled by default and can be enabled in source settings. Read-only sources and media servers do not write files back; FTP/FTPS does not support write-back. Existing files are preserved.

Right-click a title to add it to a collection or create a new one. The management page lets you edit collection names, covers, and members; deleting a collection does not delete its media. TMDB movie franchises appear when at least two titles in the franchise are in the library. Jellyfin/Emby collections are refreshed with their servers. Daily picks and collections can be opened in the **Movie Showcase** to play titles or view their details; use the upper-left back button to return. The showcase uses title artwork as its background, and cast and crew portraits open their works in the current library. **Daily Picks** displays up to ten titles per day in a fixed order for that day. Transparent logos in the showcase can automatically resize to fit their content. Enable this under **Settings → Media Library → Media Library Preferences**; it is disabled by default. Logos remain automatically centered when the setting is disabled.

Right-click a title, season, or resource cover to create a playlist or add it to an existing one. For titles available from multiple sources, select a source first. Each playlist is tied to one source but can contain both movies and TV episodes. Title- and season-based playlists automatically append new episodes, and members can be reordered or removed manually.

Click **Playlists** in the media library toolbar to open the management page. After opening a playlist, the information bar at the top shows its cover, source, number of entries, and number of titles, along with **Play All**, **Shuffle**, and **Loop** controls. Single-click an entry to select it; double-click or click the play button to start playback. Drag the handle to reorder entries. Menus allow you to remove members, rename playlists, or delete playlists. Unavailable resources remain listed.

Right-click a playlist or individual episode cover to refresh metadata, update watched status, or add it to another playlist. Duplicating a playlist preserves its members and order; duplicating an episode copies only that entry. Adding to an existing playlist skips duplicates. Episodes are sorted by air date or season and episode number, while manual ordering is preserved.

Custom playlists require MPV and support videos in the library, STRM files, and videos that media servers allow to be played directly. New playback sessions use the current playlist order. **Shuffle** creates a shuffled order for the current session. With **Loop** enabled, playback returns to the first available entry after the last entry finishes. Resume playback restores the order captured at the start of the session. Jellyfin/Emby playlists are read-only, but can be copied into editable custom playlists.

Right-click a title, season, resource, playlist, or Continue Watching cover and select **Cache Video...**. Confirm the version, associated files, total size, and destination directory before downloading. Playback prioritizes local files when a complete cache is available. Caching an ISO downloads the entire disc image; caching a BDMV downloads the entire disc directory. Sources must supply file size and version information sufficient for safe resumable downloads. If storage space is insufficient, the entire batch will not start.

The default directory is `stream_path_data/video_cache/`. Change it under **Settings → Cache → Offline Video Cache**, or choose a temporary destination in the confirmation dialog. The circular download button expands to show progress, speed, and pause/resume controls. Downloads pause automatically during online playback, and closing the application preserves resumable progress. Downloads can be deleted from the management screen in Settings. Standard cache cleanup and library exports preserve downloaded video files. See the [Offline Video Cache Guide](docs/视频离线缓存.md).

The details page offers **Start Playback** or **Resume Playback**; TV series start at S01E01 by default. The Continue Watching and Recently Played menus let you refresh status or mark items as watched. Right-click an empty area of the media library and select **Refresh Playback Status** to refresh playback sessions together. Resume playback advances automatically when a next episode exists. Duration is taken from probe results when available, otherwise from official metadata.

On a TV series details page, use the selector beside the play button to choose a default version for the whole series, or the selector on the right of each season to choose a version for that season. Choices persist after restarting the application. Reselecting a series-wide version applies it to all seasons. Mapped regular episodes appear only once; episodes missing from the selected version are hidden. You can manually switch versions when one is temporarily unavailable. Use **Confirm Version Assignment** to name duplicate files that cannot be distinguished automatically.

After switching versions, click Play again to apply the change. Resume playback uses progress saved for that specific version. With automatic season transitions enabled, if the next season needs another source, MPV exits first. The main application then prompts **Continue Playback** or **Play Later**, and restarts the player only if you choose to continue.

Blu-ray ISO/BDMV and DVD ISO support external `.ass`, `.ssa`, and `.srt` subtitles. First enable **Automatically Inject Matching External Subtitles, Fonts, and LRC** under **Settings → Playback → Playback Behavior**. Then open **Disc External Subtitles** from Folders or the playback bottom bar, or **Blu-ray External Subtitles / DVD External Subtitles** from the title window. For each title, choose **Auto Suggest**, **Do Not Use External Subtitles**, or a specific file. See [External Subtitle Naming and Usage for ISO and BDMV](docs/ISO与BDMV外挂字幕命名与使用.md) for naming conventions, directory locations, and matching rules.

Under **Settings → Playback → Playback Behavior**, enable **Insert Specials by Decimal Episode Number** (disabled by default) to place specials such as Episode 11.5 between the corresponding regular episodes in implicit playlists, based on decimal episode numbers in the specials' metadata titles. If season assignment is unclear or the episode number falls outside the season's range, air-date ordering is preserved. Save the setting and start playback again to apply it; custom playlists keep their existing order.

**Implicit Playlist Episode Limit**, in the same settings category, defaults to 2 (the current episode and the next). Set it from 2 to 10 to control how many episodes are loaded into MPV at once. Higher values reduce delays between episodes but prefetch more episodes and consume additional network and cache resources. Changes apply to newly started or newly taken-over sessions after saving. Traditional full playlists are unaffected.

**Spoiler Protection** can be enabled in media library settings. Covers and descriptions of unwatched titles are masked; **Reveal Spoilers** temporarily removes the mask. Marking a title as unwatched restores it.

Under **Settings → Media Library → Media Library Preferences**, enable **Show Season / Movie Counts** to display a second line under each title's cover, such as `2023 · 2 Seasons` or `2023 · 2 Items`. Movie resources include regular video files, STRM, ISO, and BDMV. The option is disabled by default, showing only the year.

Import or export ZIP backups in the media library settings. Backup files are saved in the `stream_path_data/` root directory. During import, select categories and source mappings. Conflicts preserve local data, and repeated imports do not create duplicates. Backups exclude passwords, active players, temporary playback URLs, and custom playlists. Watched status cannot be imported during playback.

Under **Settings → Interface → Interface Style**, choose and save an accent color: blue, cyan, green, lime, yellow, orange, pink, magenta, purple, or white. Blue is the default. White appears white in dark mode and uses a distinguishable neutral color in light mode.

## Compatibility & Data Storage

- **Operating System:** Windows 10/11 x64.
- **Player:** MPV is the primary supported player. Other external players can also be used for video and audio via configurable player argument templates.
- **Blu-ray and DVD:** Supports title playback for unencrypted Blu-ray and optional native HDMV/BD-J menus; menu compatibility depends on the selected MPV build. Java for BD-J is bundled with the application, so system-wide Java configuration is unnecessary. Remote menu playback requires installing the bundled WinFsp. DVD ISO uses title playlists; DVD menus and CSS decryption are not provided. Network playback requires random-access Range reads and resource version validation. AACS/BD+ decryption is not supported.
- **Portable Data:** Settings, cache, and playback history are stored by default in `stream_path_data/` alongside the executable.
- **Installed Version Data:** Settings, cache, and playback history are stored in `%LOCALAPPDATA%\StreamPath\stream_path_data\`, separate from the installation directory.
- **Media Servers:** Supports direct playback and synchronization of progress and watched status. Transcoding, live streaming, and remote control are not provided. Offline records are synchronized after reconnecting.
- **Network Protocols:** Playback sources must support random reads. Unsupported sources produce an explicit warning rather than downloading the entire media file. See the Blu-ray support details above.

## Warning

This project only manages and plays media provided by users. It does not provide any media content. Movies in the demonstrations are shown solely to illustrate media metadata.

For more details about architecture, protocols, and compatibility, see [Technical Details & Compatibility](docs/PROJECT.md).
