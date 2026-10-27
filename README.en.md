<h1 align="center">StreamPath</h1>

<p align="center">Browse network storage, local media, and media servers on Windows, and play with MPV.</p>
<p align="center">Windows 10/11 x64 · WebDAV / SMB / FTP / NFS · Jellyfin / Emby · Media Library</p>
<p align="center"><a href="#quick-start">Quick Start</a> · <a href="#media-library-basics">Media Library Basics</a> · <a href="docs/PROJECT.md">Technical and Compatibility Notes</a></p>

<p align="center"><img src="docs/images/readme/library-home.png" alt="StreamPath Media Library Home" width="100%"></p>
<p align="center"><sub>Media Library Home</sub></p>

<table>
  <tr>
    <td width="50%"><img src="docs/images/readme/series-detail.png" alt="Title Details Page" width="100%"></td>
    <td width="50%"><img src="docs/images/readme/episode-list.png" alt="Episode List" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><sub>Title details, cast and crew, and related resources</sub></td>
    <td align="center"><sub>Episode browsing, synopsis, and watch progress</sub></td>
  </tr>
</table>

<p align="center"><img src="docs/images/readme/movie-showcase.png" alt="Movie Showcase Page" width="100%"></p>
<p align="center"><sub>Movie Showcase Page</sub></p>

## What StreamPath Can Do

| Feature                  | Description                                                                                                                         |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| 🎬 Media Library         | Browse movies, TV series, collections, daily picks, title details, and episodes; supports TMDB and local NFO metadata.              |
| 🌐 Multi-Source Browsing | Browse WebDAV, SMB, FTP/FTPS, NFS, and local folders; also connect to Jellyfin and Emby.                                            |
| ▶️ Video and Music       | Play video, audio, and STRM with MPV; supports resume, automatic next-episode, external subtitles and fonts, lyrics, and cover art. |
| 💿 Blu-ray               | Local ISO/BDMV with optional menu or main title; WebDAV supports playback by Title; HDMV menus are a beta feature.                  |
| 🕘 Favorites and History | View favorites, resume, and recently played by source; import and export metadata and personal status by category.                  |

Supports Simplified Chinese, Traditional Chinese, Japanese, and English. OpenList/AList can connect via WebDAV; search, restore, and other features depend on server capabilities.

## Quick Start

1. Get the Windows x64 installer (`.setup.exe`) from the project's [Releases](../../releases) page and install it with the wizard; alternatively, extract the portable package (`.portable.zip`) and run `streampath.exe`.
2. In "Settings → Playback", select the player executable; MPV is recommended.
3. Add a media source:
   - **WebDAV:** Create a profile in "Settings → Servers", then add a WebDAV mount in "Folders → Network Storage". Enter the server address and account; leave the password blank if empty passwords are allowed.
   - **Local Folder:** Add a directory in "Folders → Local Folders".
   - **SMB, FTP/FTPS, NFS:** Add a connection in "Folders → Network Storage" and enter the protocol address and account; configure the SMB domain, NFS version, and UID/GID as needed.
   - **Jellyfin, Emby:** Add a server and account in "Folders → Media Servers", then select the server from the top of the media library to browse titles and play available versions.
4. Open "Folders", enter a media directory, and click a video, audio, or STRM file to play it.

Player format support is determined by the configured player. When playing STRM files on OpenList, it is recommended to enable "Enable Signing" in the corresponding storage settings.

## Installation and Software Updates

The installed version is installed to `%LOCALAPPDATA%\Programs\StreamPath` by default, is available only to the current user, and requires no administrator privileges. You can change the installation directory or create a desktop shortcut; uninstalling does not delete user data.

View the version or manually check in "Settings → General → Software Updates". The software also checks for official Releases at startup and downloads the applicable installer or portable version in the background. After the download completes, click "Restart to Update"; please end playback, scanning, and importing first. The software will save its state and restart.

Updates preserve the data of the current copy; the installed and portable versions use their own data directories and do not move data from other copies. Older versions must be upgraded manually first; automatic updates are unavailable when a Release lacks a release manifest or matching files.

## Media Library Basics

1. First add a media source. The "Main Media Library" aggregates enabled directories; you can also select Jellyfin or Emby from the top drop-down box.
2. Open "Folders → Media Library" and add a movie or TV series directory.
   Through "Edit Media Directory", you can modify the name, source, type, and scan settings; local/WebDAV directories can also configure metadata reading, write-back, and read-only.
3. Click "Manual Scan"; once complete, you can browse titles.
4. If you need TMDB metadata, save and verify the **Read Access Token** in the media library settings; scanning and playback also work without it.

The top of "Folders → Media Library" shows collection statistics for enabled directories: "TV Episodes" is the number of individual episode entries, "TV Series" is the number of complete series, "Movies" includes regular movies, ISO, and BDMV, and "Other" is unrecognized entries. Multiple versions of the same movie or episode are counted separately, while complete series are deduplicated by title; disabled directories and missing resources are not counted, and the statistics update automatically after scans and directory toggle changes.

The media library identifies media based on file names and directories and does not read file contents or probe duration, tracks, or other information. File names with season and episode numbers are more likely to be categorized correctly.

In "Settings → Media Library → Media Library Preferences", enter comma-separated "Blocked Folder Names" and save. Fuzzy mode matches by keyword, exact mode matches by full name, and both are case-sensitive. Matching directories and subdirectories are skipped during scanning and removed from the list during subsequent scans or scraping; clear the names and rescan to restore them.

The directory card toggle enables or disables the media library. When disabled, related titles, collections, and source entries are hidden and do not participate in playback, next-episode switching, or scheduled scans; personal records are retained and restored when re-enabled. Automatic scanning defaults to once per day, with a minimum interval of six hours, and runs only when the software is idle; you can also specify a subdirectory to scan.

Local metadata mode prioritizes existing NFOs and posters and pauses automatic network matching; network mode reads local metadata when network metadata is missing. Write-back is off by default and can be enabled in source settings. Read-only sources and media servers do not write back; FTP/FTPS does not support write-back, and existing files are retained.

Right-click a title to add it to or create a collection; the management page can modify the name, cover, and members; deleting a collection does not delete media. TMDB movie series are displayed when the library contains at least two titles; Jellyfin/Emby collections refresh with the server. Daily picks and collections can enter the movie showcase to select a title to play or view details, and the top-left corner returns to the previous level. The showcase uses title images as the background, and cast and crew avatars can show titles in this library; daily picks include at most ten titles per day, and the order is fixed for the day. Transparent logos in the showcase can adapt in size to the content and can be enabled in "Settings → Media Library → Media Library Preferences"; they are off by default and are still automatically centered when disabled.

Right-click a title, season, or resource cover to create or add to a playlist. Titles from different sources can first select a source; each list is fixed to one source and can mix movies and TV series. Title/season lists automatically append new episodes and can also be manually sorted and have members removed.

Click "Playlists" in the media library toolbar to enter the management page; after entering a list, the information bar above shows the cover, source, entry count, and title count, and provides "Play All", "Shuffle Play", and "Loop Play". Single-click to select an entry, double-click or click the play button to start playback; drag the handle to adjust the order. The menu can remove members, rename, or delete the list; unavailable resources are still retained.

Right-click a list or episode cover to refresh metadata, mark watch status, or add to another list. Copying a list preserves members and order; copying an episode copies only the current entry; duplicates are skipped when adding to an existing list. Episodes are sorted by first air date or season/episode number, and manual order remains effective.

Custom playlists require MPV and support in-library videos, STRM, and server direct-play videos. New playback uses the current list order; "Shuffle Play" establishes this session in shuffled order; when "Loop Play" is enabled, the end of the last item returns to the first available entry and continues. Resume restores the order at the start of playback. Jellyfin/Emby lists are read-only; copy them to a custom list to edit. See [Custom Playlist Documentation](docs/影视库自定义播放列表.md) for details.

Right-click a title, season, resource, playlist, or continue-watching cover and select "Cache Video…", then confirm the version, attachments, capacity, and save directory before downloading. Full cached playback prioritizes local files; ISO downloads the complete image, and BDMV downloads the entire disc directory. The source must provide size and version information that supports safe resumption; if space is insufficient, the entire batch will not start.

The default directory is `stream_path_data/video_cache/`, which can be changed in "Settings → Cache → Video Offline Cache" or temporarily selected in the confirmation window. The circular download button can expand progress, speed, and pause/resume operations; it automatically pauses during online playback, and closing the software preserves the breakpoint. The management entry in settings can delete downloads; normal cache cleanup and library export preserve video files. See [Video Offline Cache Documentation](docs/视频离线缓存.md) for details.

The details page provides "Start Playing" or "Resume Playing"; TV series start from S01E01 by default. The continue-watching and recently played menus can refresh status or mark as watched; right-click a blank area of the media library and select "Refresh Playback Status" to refresh playback sessions uniformly. When there is a next episode, resume automatically advances.

To the right of the play button on the series details page, you can select the default version for the entire series, and on the right side of the season list, you can select the version for the current season separately; the selection is retained after restart. Re-selecting the entire-series version unifies all seasons. Mapped regular episodes are displayed only once per episode, and episodes missing from the selected version are hidden; if a version is temporarily unavailable, you can manually select another. Duplicate files that cannot be automatically distinguished can be assigned names through "Confirm Version Attribution".

After switching versions, click play again for it to take effect; resume uses that version's own progress. When automatic next-episode is enabled and the next season requires another source, MPV exits first, and the main program then prompts "Continue Playing" or "Play Later"; playback restarts only if you choose to continue.

Blu-ray ISO/BDMV supports external `.ass`, `.ssa`, and `.srt` subtitles: first enable "Automatically inject matching external subtitles, external fonts, and LRC" in "Settings → Playback → Playback Behavior", then right-click in the folder menu, the ISO title selection window, or the playback bottom bar and click "Blu-ray External Subtitles" to select "Auto Suggest", "Do Not Use External Subtitles", or a specific file for each MPLS. See [ISO and BDMV External Subtitle Naming and Usage](docs/ISO与BDMV外挂字幕命名与使用.md) for naming, directory location, and matching rules.

In "Settings → Playback → Playback Behavior", you can enable "Insert Specials by Decimal Episode Number" (off by default). The implicit playlist of recognized series will, based on the decimal episode number in the special episode metadata title, insert episode 11.5 and similar between the corresponding regular episodes; when season attribution is unclear or the episode number exceeds the season range, first-air ordering is retained. The change takes effect after saving and restarting playback; custom lists retain their original order.

The "Implicit Playlist Episode Limit" for the same category defaults to 2 (current episode plus next episode) and can be set from 2 to 10, indicating the number of episodes attached to MPV at the same time. Increasing it reduces waiting when switching episodes but prepares more episodes in advance and consumes more network and cache; after saving, it takes effect for sessions that are restarted or re-adopted, and traditional full lists are unaffected.

In the media library settings, you can enable the "Spoiler Prevention" mask; covers and synopses of unfinished titles can be temporarily revealed with "Show Spoilers", and the mask is restored after marking as unwatched.

In "Settings → Media Library → Media Library Preferences", enable "Show Season/Title Count", and the second line of the title cover will display, for example, `2023·2 Seasons` or `2023·2 Items`; movie resources include regular videos, STRM, ISO, and BDMV. It is off by default and shows only the year.

You can import or export ZIP backups in the media library settings; files are saved in the root directory of `stream_path_data/`. When importing, select the category and source mapping; conflicts retain local metadata, and repeated imports do not create duplicate records. Backups do not include passwords, active players, temporary playback addresses, or custom playlists; watch status cannot be imported during playback.

In "Settings → Interface → Interface Style", select an accent color and save. Blue, cyan, green, lime green, yellow, orange, pink, magenta, purple, and white are available; the default is blue. White appears white in dark interfaces and uses an easily recognizable neutral color in light interfaces.

## Support Scope and Data

- **System:** Windows 10/11 x64.
- **Player:** MPV is the primary support target; video and audio can also use other external players according to player parameter templates.
- **Blu-ray:** Supports unencrypted Blu-ray. WebDAV playback requires the server to support random Range reads and resource version verification; DVD, AACS/BD+ encrypted discs, and BD-J are not supported. HDMV menus are an optional beta feature.
- **Portable Data:** Configuration, cache, and playback records are saved by default in the `stream_path_data/` directory alongside the program.
- **Installed Version Data:** Configuration, cache, and playback records are saved in `%LOCALAPPDATA%\StreamPath\stream_path_data\`, separate from the installation directory.
- **Media Servers:** Supports direct playback and progress/watch status synchronization; does not provide transcoding, live TV, or remote control. Offline records sync after reconnection.
- **Network Protocols:** Playback sources must support random reads; unsupported sources will be clearly indicated and will not be downloaded in full. See above for Blu-ray support scope.

## Warning

This project only manages and plays user-provided media and does not provide content sources; demo videos are for displaying media metadata only.

For more architecture, protocol, and compatibility details, see [Technical and Compatibility Notes](docs/PROJECT.md).
