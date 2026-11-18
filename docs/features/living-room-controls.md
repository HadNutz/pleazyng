# Living-room controls

## Play from a poster

Focus a movie or episode and press the hardware Play or Play/Pause key to start or resume. On a show or season, the player resolves an episode first. OK keeps your configured selection behavior. When music already owns playback, the media key remains available to the music session.

## Missing episodes

If the next numbered episode jumps forward within a season, playback waits for a choice. Cancel to stay, explicitly skip to the later episode, or play the missing episode when an accessible library has a copy with a matching series identity and episode number. Downloads use the local sequence. Specials, shuffled queues, and deliberately reordered sequences are handled separately.

## Older Dolby Digital receivers

Under **Settings → Playback → Audio**, enable **Dolby Digital 5.1 for older receivers** on the playback device. For eligible server-backed multichannel tracks, Pleazyng requests AC-3 audio, up to six channels. Compatible video can be stream-copied. The server must permit audio transcoding and the output chain must pass Dolby Digital. Stereo and an existing AC-3 track keep their usual path. Audio normalization takes precedence when enabled.

## Guest jukebox

Start a music queue. In **Now Playing → More → Guest jukebox**, choose the library, open the room, and show the QR code to someone on your local network. A guest can search tracks and append a result. The host controls playback and queue order. Close the jukebox to revoke the link. Replacing or stopping the host queue also closes the room.

## Projector or masked screen

Open **Settings → Appearance → Fit to my screen**. Select an edge and move it with the remote arrows or the on-screen controls. Fit all four edges and save. The app uses the resulting rectangle for its menus, video player and overlays. Cancel discards the edit. Reset followed by Save restores the full screen.

## Overtime recordings

While a local scheduled IPTV recording is running, choose **Record 30 more minutes** on the live channel or in **Live TV → Recordings**. Each successful press adds 30 minutes to the current stop time. The confirmation displays the revised local time. Extending keeps the existing capture and recording file open.

## Original dialogue

In **Settings → Playback → Audio**, enable **Prefer original dialogue**. An explicit audio selection takes priority. With no override, Pleazyng looks for a main audio track flagged as original. If no track has that flag, a verified original language can identify a single main dialogue track. On direct playback, a capable engine can also read original-track flags from the file when the server supplies no decision. Ambiguous matches leave the usual selection in effect. Movie language lookup through a configured Seerr connection uses the exact TMDB movie ID.

## Comic spreads

In a comic’s two-page view, open the reader options and choose **Show this page alone** for the physical page that breaks a spread. On a two-page spread you can choose either page by number. Reopen the same menu on an isolated page to restore normal pairing. Corrections belong to that issue and profile. Physical page numbers, bookmarks and reading direction stay consistent.

## Audio description on a paired phone

Pair the Android or iOS companion remote with the playback device on your local network. Start a server-backed video, then open **Playback → Listen on this phone** on the phone. Both devices need access to the same server and edition. Connect headphones and select an embedded audio track. A single track flagged for audio description is selected automatically. The TV keeps its own soundtrack.

Keep the listening screen open. The phone follows TV pauses, playback speed, seeks and edition changes. Use the audio sync slider to compensate for headphone delay. When headphones disconnect, playback on the phone pauses. Reconnect or use the on-screen play control to resume. Leaving the screen ends personal listening.

## Show rotation

Open a show's menu, select **Show rotation**, and add the show. Repeat from any connected TV library, then choose **Play**. Each round plays the next unwatched episode of each eligible series in a shuffled show order. In-progress episodes keep their resume position. The next session checks watch history again and continues the saved round. A missing numbered episode holds that series at the gap. Other shows can continue.

## HDR subtitle brightness

During HDR playback, open **Tracks → Subtitle styling → HDR subtitle brightness**. The preview pauses on the current frame. Adjust the level, then save or cancel to return to playback. The saved level follows the display. On mpv GPU Next, the control uses the installed text or image subtitle white-level option when supported. The native text option also changes mpv's own on-screen text. Embedded mpv renderers can dim plain text using its foreground colour when they report HDR output. Returning to SDR restores the ordinary style.

## Bilingual stereo tracks

In the player's audio settings, choose **Channel to play through both speakers**. Select **Left**, **Right**, or **Stereo** to audition it, then save for the current version and file. The mpv path uses a labelled decoded-audio filter. Android ExoPlayer uses its stereo PCM mixing matrix when the active output supports processing. Encoded passthrough, multichannel input, and ExoPlayer tunnelling or offload keep their existing audio route.

## Comic reading lists

In the Comics shelf, open **Reading lists** and import a ComicRack `.cbl` file. Scan the connected comic sources first. Each list keeps its original order, including missing issues and alternate editions. Use the link button to choose an edition or search the indexed comics across sources. **Read next** opens the earliest unfinished position in the reader, or opens the picker if that position needs a match. Choose a later row to read ahead. Matching choices and reading progress belong to the active profile.

## Upstream sources

- HDR subtitle brightness draws on the OLED viewing problem addressed by [barnebyte’s PlexOledSubtitles](https://github.com/barnebyte/PlexOledSubtitles). Pleazyng adjusts playback rendering and keeps the subtitle file intact.
- Series rotation draws on [raykwonx’s next-unwatched shuffle request](https://forums.plex.tv/t/shuffle-play-my-shows-but-only-play-the-next-unwatched-episode-of-that-show/936507).
- Stereo channel selection addresses the [bilingual soundtrack use case reported by Plex viewers](https://www.reddit.com/r/PleX/comments/oqu872/).
- Cross-library reading lists draw on [Kavita’s CBL importer](https://wiki.kavitareader.com/guides/features/cbl-import/) and the [Komga reading-order discussion](https://github.com/gotson/komga/issues/1803).

- Hardware Play on a focused poster draws on the upstream feature requests [Plezy #1510](https://github.com/edde746/plezy/issues/1510) by [@enchained](https://github.com/enchained) and [Plezy #3038](https://github.com/edde746/plezy/issues/3038) by [@fillilutten](https://github.com/fillilutten).
- The missing-episode prompt draws on the upstream feature request [Jellyfin Android TV #4566](https://github.com/jellyfin/jellyfin-androidtv/issues/4566) by [@hufforguk](https://github.com/hufforguk).
- Dolby Digital receiver output draws on the upstream feature request [Plezy #3054](https://github.com/edde746/plezy/issues/3054) by [@abaginski](https://github.com/abaginski) and the [Kodi audio troubleshooting](https://kodi.wiki/view/Audio_troubleshooting) guide to passthrough and AC-3 transcoding.
- The local guest music queue draws on Room Mode in [MusicLounge Jukebox](https://forums.plex.tv/t/new-app-musiclounge-jukebox/942146) by [Earthmonkey](https://forums.plex.tv/u/Earthmonkey).
- Projector calibration draws on the upstream constant-image-height request [Plezy #863](https://github.com/edde746/plezy/issues/863) by [@thehomerepot](https://github.com/thehomerepot).

- Extending an active sports recording draws on [gingie’s Channels DVR request](https://community.getchannels.com/t/extend-live-recordings/1789).
- Original dialogue selection draws on [@Altarentys’s Plezy request #3019](https://github.com/edde746/plezy/issues/3019).
- Per-issue comic spread correction draws on the pairing problem reported by [@fatherpanda in Kavita #4903](https://github.com/Kareadita/Kavita/issues/4903).
- Synchronized personal audio description takes inspiration from [GRETA by Greta & Starks Apps GmbH](https://apps.apple.com/ca/app/greta/id793892423). Pleazyng uses the listener’s own server file and embedded tracks.

Pleazyng implemented these features independently. See the [attribution ledger](../../UPSTREAM_ATTRIBUTION.md).
