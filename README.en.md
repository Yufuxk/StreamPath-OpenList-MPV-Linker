<h1 align="center">StreamPath</h1><p align="center">Browse network storage, local media, and media servers on Windows, and play with MPV.</p>
<p align="center">Windows 10/11 x64 · WebDAV / SMB / FTP / NFS · Jellyfin / Emby · Media Library</p>
<p align="center"><a href="#quick-start">Quick Start</a> · <a href="#media-library-basics">Media Library Basics</a> · <a href="docs/PROJECT.md">Technical & Compatibility Notes</a></p><p align="center"><img src="docs/images/readme/library-home.png" alt="StreamPath Media Library Home" width="100%"></p>
<p align="center"><sub>Media Library Home</sub></p><table>
 <tr>
 <td width="50%"><img src="docs/images/readme/series-detail.png" alt="Title Detail Page" width="100%"></td>
 <td width="50%"><img src="docs/images/readme/episode-list.png" alt="Episode List" width="100%"></td>
 </tr>
 <tr>
 <td align="center"><sub>Title details, cast & crew, and related resources</sub></td>
 <td align="center"><sub>Episode browsing, synopsis, and watch progress</sub></td>
 </tr>
</table><p align="center"><img src="docs/images/readme/movie-showcase.png" alt="Movie Showcase Page" width="100%"></p>
<p align="center"><sub>Movie Showcase Page</sub></p>

## What StreamPath Can Do

| Feature                  | Description                                                                                                                  |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| 🎬 Media Library         | Browse movies, series, collections, daily picks, title details, and episodes; supports TMDB and local NFO metadata.          |
| 🌐 Multi-Source Browsing | Browse WebDAV, SMB, FTP/FTPS, NFS, and local folders, or connect to Jellyfin and Emby.                                       |
| ▶️ Video & Music         | Play video, audio, and STRM with MPV; supports resume, auto next episode, external subtitles & fonts, lyrics, and cover art. |
| 💿 Blu-ray               | Local ISO/BDMV with optional menu or main title; WebDAV supports title-based playback; HDMV menus are a test feature.        |
| 🕘 Favorites & History   | View favorites, resume, and recently played by source; import/export data and personal status by category.                   |

Supports Simplified Chinese, Traditional Chinese, Japanese, and English. OpenList/AList can be connected via WebDAV; search, restore, and other features depend on server capabilities.

## Quick Start

1. Get the Windows x64 installer (`.setup.exe`) from the project's [Releases](https://../releases) page and follow the wizard; or extract the portable package (`.portable.zip`) and run `streampath.exe`.

2. In "Settings → Playback", select the player executable; MPV is recommended.

3. Add a media source:
   
   - **WebDAV:** In "Folders → Network Storage", click Add, select WebDAV as the source type, and fill in the name, server address, and account; you may optionally fill in a default directory, and leave blank if empty passwords are allowed.
   
   - **Local Folder:** Add a directory in "Folders → Local Folders".
   
   - **SMB, FTP/FTPS, NFS:** In the same "Add Network Storage" dialog, select the corresponding protocol and fill in the protocol address and account; optionally set the SMB domain, NFS version, and UID/GID.
   
   - **Jellyfin, Emby:** Add a server and account in "Folders → Media Servers", then select the server from the top of the Media Library to browse titles and play available versions.

4. Open "Folders", navigate to the media directory, and click a video, audio, or STRM file to play.

Player format support is determined by the configured player. When playing STRM files on OpenList, it is recommended to enable "Enable Signing" in the corresponding storage settings.

## Installation & Software Updates

The installer defaults to `%LOCALAPPDATA%\Programs\StreamPath`, is available only to the current user, and requires no administrator privileges. You can change the install directory or create a desktop shortcut; uninstalling does not delete user data.

Check the version or manually check in "Settings → General → Software Updates". The software also checks for official Releases on startup and downloads the applicable installer or portable package in the background. After downloading, click "Restart to Update"; please end playback, scanning, and importing first — the software will save its state and restart.

Updates preserve the current copy's data; the installer and portable versions use their own data directories and will not migrate data from other copies. Older versions must be upgraded manually first; automatic updates are unavailable if the Release lacks a manifest or matching files.

## Media Library Basics

1. Add media sources first. "Main Library" aggregates enabled directories; you can also select Jellyfin or Emby from the top dropdown.

2. Open "Folders → Media Library" and add movie or series directories.  
   Via "Edit Media Directory", you can modify the name, source, type, and scan settings; local/WebDAV directories can also set metadata reading, write-back, and read-only.

3. Click "Manual Scan"; once complete, you can browse titles.

4. If you need TMDB metadata, save and verify the **Read Access Token** in the Media Library settings; scanning and playback work without it.

The top of "Folders → Media Library" shows collection statistics for enabled directories: "TV Episodes" is the number of individual episode entries, "TV Series" is the number of complete series, "Movies" includes regular movies, ISO, and BDMV, and "Other" is unrecognized entries. Multiple versions of the same movie or episode are counted separately, while complete series are deduplicated by title; disabled directories and missing resources are not counted, and statistics update automatically after scanning or directory toggle changes.

The Media Library identifies media by filename and directory, without reading file contents or probing duration, tracks, or other information. Filenames with season/episode numbers are more likely to be categorized correctly.

In "Settings → Media Library → Media Library Preferences", enter comma-separated "Blocked Folder Names" and save. Fuzzy mode matches by keyword, exact mode matches by full name, and both are case-sensitive. Matching directories and subdirectories are skipped during scanning and removed from lists during subsequent scans or scraping; clear the names and rescan to restore.

The directory card toggle enables or disables the media library. When disabled, related titles, collections, and source entries are hidden and excluded from playback, episode switching, and scheduled scanning; personal records are retained and restored upon re-enabling. Automatic scanning defaults to once per day with a minimum interval of six hours, running only when the software is idle; you can also specify subdirectory scans.

Local metadata mode prioritizes existing NFOs and posters and pauses automatic network matching; network mode reads local metadata when network data is missing. Write-back is off by default and can be enabled in source settings. Read-only sources and media servers do not write back; FTP/FTPS does not support write-back, and existing files are preserved.

Right-click a title to add it to or create a collection; the management page lets you modify the name, cover, and members; deleting a collection does not delete media. TMDB movie series are shown when the library contains at least two titles; Jellyfin/Emby collections refresh with the server. Daily Picks and collections can enter the Movie Showcase to play a title or view details; the top-left corner returns to the previous level. The showcase uses title images as backgrounds, and cast avatars can show titles in this library; Daily Picks are limited to ten titles per day with a fixed order for the day. Transparent logos in the showcase can auto-size to content and can be enabled in "Settings → Media Library → Media Library Preferences", default off; when off, they are still automatically centered.

Right-click a title, season, or resource cover to create or add to a playlist. Cross-source titles require selecting a source first; each list is fixed to one source and can mix movies and series. Title/season lists automatically append new episodes, and members can be manually sorted and removed.

Click "Playlists" in the Media Library toolbar to enter the management page; after entering a list, the top info bar shows the cover, source, entry count, and title count, and provides "Play All", "Shuffle Play", and "Loop Play". Single-click to select an entry; double-click or click the play button to start playback; drag the handle to reorder. The menu can remove members, rename, or delete the list; unavailable resources are retained.

Right-click a list or episode cover to refresh metadata, mark watch status, or add to another list. Copying a list preserves members and order; copying an episode copies only the current entry; adding to an existing list skips duplicates. Episodes are sorted by air date or season/episode number, and manual order remains valid.

Custom playlists require MPV and support in-library videos, STRM, and server direct-play videos. New playback uses the current list order; "Shuffle Play" establishes a shuffled order for the current session; with "Loop Play" enabled, the end of the last item returns to the first available entry to continue. Resume restores the order at the start of playback. Jellyfin/Emby lists are read-only; copy them to a custom list to edit. See [Custom Playlist Guide](https://docs/%E5%BD%B1%E8%A7%86%E5%BA%93%E8%87%AA%E5%AE%9A%E4%B9%89%E6%92%AD%E6%94%BE%E5%88%97%E8%A1%A8.md) for details.

Right-click a title, season, resource, playlist, or continue-watching cover and select "Cache Video…" to download after confirming the version, attachments, size, and save directory. Complete cached playback prioritizes local files; ISO downloads the full image, and BDMV downloads the entire disc directory. The source must provide safe resumable size and version information; if space is insufficient, the entire batch will not start.

The default directory is `stream_path_data/video_cache/`, which can be changed in "Settings → Cache → Video Offline Cache" or temporarily selected in the confirmation dialog. The circular download button expands progress, speed, and pause/resume controls; it automatically pauses during online playback and preserves breakpoints when the software is closed. The management entry in settings can delete downloads; regular cache cleanup and library export preserve video files. See [Video Offline Cache Guide](https://docs/%E8%A7%86%E9%A2%91%E7%A6%BB%E7%BA%BF%E7%BC%93%E5%AD%98.md) for details.

The detail page provides "Start Playing" or "Resume Playing"; series default to starting from S01E01. The Continue Watching and Recently Played menus can refresh status or mark as watched; right-click a blank area in the Media Library and select "Refresh Playback Status" to refresh playback sessions uniformly. Resume automatically advances when there is a next episode. Duration prioritizes probe results, otherwise uses official metadata.

On the series detail page, the default version for the entire series can be selected to the right of the play button, and the current season version can be selected separately to the right of the season list; selections persist after restart. Re-selecting the entire series version unifies all seasons. Mapped regular series show each episode only once, and episodes missing from the selected version are hidden; you can manually reselect when a version is temporarily unavailable. Duplicate files that cannot be automatically distinguished can be assigned via "Confirm Version Assignment".

After switching versions, click play again for it to take effect; resume uses that version's own progress. With auto next season enabled, when the next season requires another source, MPV exits first, and the main program then prompts "Continue Playing" or "Play Later"; playback restarts only if you choose to continue.

Blu-ray ISO/BDMV supports external `.ass`, `.ssa`, and `.srt` subtitles: first enable "Auto-inject matching external subtitles, external fonts, and LRC" in "Settings → Playback → Playback Behavior", then click "Blu-ray External Subtitles" in the folder right-click menu, the ISO title selection window, or the playback bottom bar to select "Auto Suggest", "Do Not Use External Subtitles", or a specific file for each MPLS. See [ISO & BDMV External Subtitle Naming and Usage](https://docs/ISO%E4%B8%8EBDMV%E5%A4%96%E6%8C%82%E5%AD%97%E5%B9%95%E5%91%BD%E5%90%8D%E4%B8%8E%E4%BD%BF%E7%94%A8.md) for naming, directory location, and matching rules.

In "Settings → Playback → Playback Behavior", you can enable "Insert Specials by Decimal Episode Number" (default off). The implicit playlist of recognized series will insert episodes like 11.5 between the corresponding main episodes based on the decimal episode number in the special's metadata title; when the season attribution is unclear or the episode number is outside the season range, the air-date order is retained. Changes take effect after saving and restarting playback; custom lists retain their original order.

The "Implicit Playlist Episode Limit" for the same category defaults to 2 (current episode plus next episode) and can be set from 2 to 10, indicating the number of episodes simultaneously mounted in MPV. Increasing it reduces waiting during episode switching but prepares more episodes in advance and consumes more network and cache; changes take effect for sessions restarted or re-adopted after saving, and traditional full lists are unaffected.

You can enable the "Spoiler Protection" mask in the Media Library settings; covers and synopses of unwatched titles can be temporarily revealed with "Show Spoilers", and the mask is restored after marking as unwatched.

In "Settings → Media Library → Media Library Preferences", enable "Show Season/Title Count" to display `2023·2 Seasons` or `2023·2 Items` on the second line of title covers; movie resources include regular videos, STRM, ISO, and BDMV. Default off, showing only the year.

You can import or export ZIP backups in the Media Library settings; files are saved in the root of `stream_path_data/`. When importing, select the category and source mapping; conflicts preserve local data, and repeated imports do not create duplicate records. Backups do not include passwords, active players, temporary playback addresses, or custom playlists; watch status cannot be imported during playback.

In "Settings → Interface → Interface Style", select an accent color and save. Options include blue, cyan, green, lime, yellow, orange, pink, magenta, purple, and white; default is blue; white displays as white on dark interfaces and uses an easily recognizable neutral color on light interfaces.

## Supported Scope & Data

- **System:** Windows 10/11 x64.

- **Player:** MPV is the primary support target; video and audio can also use other external players via player argument templates.

- **Blu-ray:** Supports unencrypted Blu-ray. WebDAV playback requires server support for random Range reading and resource version verification; DVD, AACS/BD+ encrypted discs, and BD-J are not supported. HDMV menus are an optional test feature.

- **Portable Data:** Configuration, cache, and playback records are saved by default in the `stream_path_data/` directory alongside the program.

- **Installed Data:** Configuration, cache, and playback records are saved in `%LOCALAPPDATA%\StreamPath\stream_path_data\`, separate from the install directory.

- **Media Servers:** Supports direct play and progress/watch status sync; does not provide transcoding, live TV, or remote control. Offline records sync after reconnection.

- **Network Protocols:** Playback sources must support random reading; unsupported sources will show a clear message and will not download the entire file. See above for Blu-ray support scope.

## Warning

This project only manages and plays media provided by users and does not provide content sources; demo films are for showcasing media metadata only.

For more architecture, protocol, and compatibility details, see [Technical & Compatibility Notes](https://docs/PROJECT.md).
