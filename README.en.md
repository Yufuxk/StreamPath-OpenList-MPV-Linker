<h1 align="center">StreamPath</h1>

<p align="center">Browse network storage, local media, and media servers in a single Windows desktop application, with playback powered by MPV.</p>
<p align="center">Windows 10/11 x64 · WebDAV / SMB / FTP / NFS · Jellyfin / Emby · Media Library</p>
<p align="center"><a href="#quick-start">Quick Start</a> · <a href="#getting-started-with-the-media-library">Media Library Guide</a> · <a href="docs/PROJECT.md">Technical Details & Compatibility</a></p>

<p align="center"><img src="docs/images/readme/library-home.png" alt="StreamPath Media Library Home" width="100%"></p>
<p align="center"><sub>Media Library Home</sub></p>

<table>
  <tr>
    <td width="50%"><img src="docs/images/readme/series-detail.png" alt="Media Details" width="100%"></td>
    <td width="50%"><img src="docs/images/readme/episode-list.png" alt="Episode List" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><sub>Media details, cast and crew, and related content</sub></td>
    <td align="center"><sub>Episode browsing, descriptions, and watch progress</sub></td>
  </tr>
</table>

## What Can StreamPath Do?

| Feature                | Description                                                                                                                                                                                   |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 🎬 Media Library       | Organize movies and TV series; browse collections, daily picks, cast and crew within your library, detailed information, episodes, and resume playback. Supports TMDB and local NFO metadata. |
| 🌐 Multiple Sources    | Mount WebDAV, SMB, FTP/FTPS, NFS, or local folders; connect to Jellyfin and Emby media libraries.                                                                                             |
| ▶️ Video & Music       | Play video, audio, and STRM files through an external player (MPV). Supports resume playback, automatic episode transitions, external subtitles and fonts, LRC lyrics, and cover art.         |
| 💿 Blu-ray             | Local ISO/BDMV sources support Blu-ray menus or main-title playback. WebDAV ISO/BDMV sources support title playback, while HDMV menus are experimental.                                       |
| 🕘 Favorites & History | Browse favorites, continue watching, and recently played items by source. Import and export selected categories of metadata and personal playback states.                                     |

The interface supports Simplified Chinese, Traditional Chinese, Japanese, and English. OpenList/AList can be accessed through WebDAV. Enhanced features such as search and recovery are enabled according to server capabilities.

## Quick Start

1. Download the Windows x64 installer (`.setup.exe`) from the project's [Releases](../../releases) page and follow the installation wizard. Alternatively, extract the portable package (`.portable.zip`) and run `streampath.exe`.
2. Go to **Settings → Playback** and select your player executable. MPV is recommended.
3. Add a media source:
   - **WebDAV:** Create a server profile under **Settings → Servers**, then navigate to **Folders → Network Storage → Add Network Storage** and select **Add WebDAV Mount**. Prepare the server address, username, and password. The password can be left blank if the server permits it.
   - **Local Folders:** Add a local directory under **Folders → Local Folders**.
   - **SMB, FTP/FTPS, NFS:** Create a connection under **Folders → Network Storage** and enter the protocol address and credentials. SMB supports domain settings, NFS supports version and UID/GID settings, and FTP uses passive mode by default.
   - **Jellyfin, Emby:** Add a server address and account under **Folders → Media Servers**. Select the server from the dropdown at the top of the media library to load its existing metadata and collections. Playback uses versions that the server permits for direct play.
4. Open **Folders**, navigate to your media directory, and click a video, audio, or STRM file to start playback.

Supported playback formats depend on the configured player. When playing STRM files hosted on OpenList, enabling **Enable Signing** in the corresponding storage settings is recommended.

## Installation & Software Updates

The installed version uses `%LOCALAPPDATA%\Programs\StreamPath` as its default installation directory. It is installed for the current Windows user only and does not require administrator privileges. You can choose a different installation directory and create a desktop shortcut. To uninstall, use Windows **Installed Apps**. Settings, cache, and playback history remain in the user data directory.

Go to **Settings → General → Software Updates** to view the current version or manually check for updates. On startup, the application automatically checks this project's official Releases and downloads a matching installer or portable update in the background. Once the download is complete, click **Restart to Update**. The application first stops playback, scanning, and import tasks, saves its state, exits, applies the update, and then restarts.

Updates preserve the settings, cache, and playback history of the current application copy. Installed and portable versions use separate data directories. Installing a new copy does not automatically migrate data from other portable copies. Older versions must first be manually updated to a version that includes the update feature. If a Release does not contain the required manifest or a matching package, the application will report that automatic updating is unavailable.

## Getting Started with the Media Library

1. Add media sources using the steps above. The dropdown at the top of the media library selects **Main Media Library** by default, aggregating all enabled media directories. Selecting a Jellyfin or Emby server allows you to browse that server's content.
2. Go to **Folders → Media Library** and add directories containing movies or TV series.
3. Click **Manual Scan**. Once scanning is complete, you can browse your content on the media library home page.
4. To retrieve and match metadata from TMDB, save and verify a TMDB **Read Access Token** in the media library settings. You can still build a media catalog and play files without configuring a token.

Scanning identifies media from filenames and directory structures. It does not read media contents or probe technical information such as duration and tracks. Including season and episode numbers in filenames helps episodes get categorized correctly.

The toggle in the upper-right corner of each directory card controls whether that media library is enabled. When disabled, its associated titles, source entries, and collection members are hidden from the media library. The directory also becomes unavailable in the source dropdown. Collections with all members hidden are hidden as well. Existing records and personal states are preserved and restored when the directory is re-enabled.

Disabled directories are excluded from scheduled scans. Directory settings provide a **Scan Selected** option for scanning a specific subdirectory. Automatic scanning runs once per day by default, with a minimum interval of six hours. It only runs while the application is open and no playback or scanning tasks are active.

**Local Metadata Mode** prioritizes existing NFO files and posters and disables automatic online matching, while still allowing manual metadata scraping. Network mode attempts to use local metadata when online metadata is unavailable.

**Allow Writing Missing NFO Files and Images** is disabled by default and must be enabled individually in the source settings. Because FTP/FTPS does not support safe file creation, automatic write-back is unavailable for these sources. Read-only sources and media servers do not support write-back, and existing files are preserved.

Right-click a title's cover and select **Add to Collection** to choose an existing collection or create a new one. The collection management page allows you to edit its name, cover, and members. Deleting a collection does not delete its media.

TMDB movie franchises are displayed when at least two available titles from the same franchise exist in the library. Custom server collections are loaded when the server is refreshed. Duplicate mounts using the same server account display only one copy of each collection in the main media library. Removing a server also removes its collections.

Click **View All** on the right side of the collections section to open the complete collection grid. Subpages share the media library's custom background across all servers. Clicking a cast or crew member's portrait opens a list of their works available in the current library. **Daily Picks** displays up to ten fixed selections per day, maintaining the same order throughout that day when switching pages, changing languages, or restarting the application.

Right-click a title, season, or media resource cover to select **Create Playlist from This Title / Season / Episode / Resource**, or choose **Add to Playlist...**.

When a title is available from multiple sources, you must select a source first. Each playlist is associated with a single source, but it can contain both movies and episodes from different series.

Bulk additions of titles or seasons use existing season and episode mappings. When multiple versions of an episode are available, the version is selected during playback. Adding an individual resource locks the entry to that specific version.

Title- and season-based playlist ranges automatically include newly added episodes, appending them to the end of the playlist. Existing manual ordering and removals remain effective.

The **Playlists** button in the media library toolbar opens a vertical playlist management page. Each row displays a small landscape cover, title, year, and season/episode information. Click once to select an item, or double-click or use the play button to start playback from that item. Drag the handle on the right to reorder entries; changes are saved when the handle is released.

The More menu allows you to remove playlist entries, while the playlist menu supports renaming and deleting playlists. Missing resources and entries from disabled sources remain in the playlist but are marked as unavailable.

Right-click a playlist's outer cover or an individual entry's cover to refresh metadata, mark content as watched or unwatched, or add it to another playlist.

**Create Playlist from This Playlist**, available from the outer cover, preserves the current members, ordering, and version settings. **Create Playlist from This Episode**, available from an individual entry, copies only that entry. Copied playlists do not inherit automatic append ranges.

When adding items to an existing playlist, only members not already present are appended, preserving their original order.

Episodes without an air date are sorted by season and episode number, with S00 placed after all regular seasons. Episodes with air dates continue to be sorted by their original air dates. Existing manually defined ordering is preserved.

Custom playlists require MPV and support regular video files in the library, existing STRM files, and videos available for direct playback from media servers.

Each new playlist playback session uses the latest playlist order. **Resume Playback** for an existing session restores the playlist snapshot captured when that session started. Subsequent playlist edits or deletion do not affect that snapshot.

Jellyfin/Emby video playlists are imported as read-only mirrors during server refreshes, preserving their remote order and duplicate entries. **Copy as Custom Playlist** creates an editable copy. Changes made to the copy are not written back to the server.

For detailed behavior, see [Custom Playlist Documentation](docs/影视库自定义播放列表.md).

The details page displays **Start Playback** or an existing resume option. TV series prioritize starting from S01E01.

The menus for Continue Watching and Recently Played allow you to refresh player status or mark the current episode as watched. If a next episode exists, the original record position is preserved while playback progress advances to the next episode.

When valid probing results are available for an episode, its actual media duration is displayed. Otherwise, the official runtime is used.

**Spoiler Protection** can be enabled in the media library settings. Covers and descriptions of unwatched content are masked, and **Reveal Spoilers** can temporarily display them. The spoiler mask is restored when content is marked as unwatched.

Use the import and export options in the media library settings to create ZIP backups.

Exported files are always saved in the application's `stream_path_data/` root directory, using the filename format `StreamPath-library-timestamp.zip`. Clicking Export saves the backup immediately.

Exporting custom collection structures is unchecked by default. During import, the application first validates the backup contents and source mappings, then allows you to select the categories to import.

When conflicts occur, local data takes precedence. Repeated imports do not create duplicate records. Importing cover preferences alone does not create missing collections. Playback states cannot be imported while playback is active.

Backups do not include passwords, running players, or temporary playback URLs. This ZIP backup feature does not include custom playlist structures.

## Compatibility & Data Storage

- **Operating System:** Windows 10/11 x64.
- **Player:** MPV is the primary supported player. Other external players can also be used for video and audio playback through configurable player argument templates.
- **Blu-ray:** Supports unencrypted Blu-ray content. WebDAV playback requires server support for random-access Range requests and resource version validation. DVD, AACS/BD+ encrypted discs, and BD-J are not supported. HDMV menus are available as an optional experimental feature.
- **Portable Data:** Settings, cache, and playback history are stored in the `stream_path_data/` directory alongside the executable by default.
- **Installed Version Data:** Settings, cache, and playback history are stored in `%LOCALAPPDATA%\StreamPath\stream_path_data\`, separately from the installation directory.
- **Media Servers:** Supports direct playback and synchronization of playback progress and watched status. Transcoding, live streaming, and remote control are not supported. During normal playback, consolidated progress updates are reported approximately every ten seconds. Pausing, seeking, switching episodes, and exiting trigger immediate updates. After reconnecting, offline states are submitted before the application retrieves the latest server state.
- **Network Protocols:** Playback requires sources that support random access. If an FTP source does not support random reads, playback fails explicitly instead of downloading the entire media file. Blu-ray support remains limited to unencrypted content and the stated HDMV capabilities.

## Disclaimer

Please note that this project is solely a tool for managing and playing media files. It does not provide any media content. All content shown in the introductory demonstrations consists entirely of metadata.

For more information about architecture, protocols, and compatibility, see [Technical Details & Compatibility](docs/PROJECT.md).
