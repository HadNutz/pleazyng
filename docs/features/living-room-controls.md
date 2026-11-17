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

## Upstream sources

- Hardware Play on a focused poster draws on the upstream feature requests [Plezy #1510](https://github.com/edde746/plezy/issues/1510) by [@enchained](https://github.com/enchained) and [Plezy #3038](https://github.com/edde746/plezy/issues/3038) by [@fillilutten](https://github.com/fillilutten).
- The missing-episode prompt draws on the upstream feature request [Jellyfin Android TV #4566](https://github.com/jellyfin/jellyfin-androidtv/issues/4566) by [@hufforguk](https://github.com/hufforguk).
- Dolby Digital receiver output draws on the upstream feature request [Plezy #3054](https://github.com/edde746/plezy/issues/3054) by [@abaginski](https://github.com/abaginski) and the [Kodi audio troubleshooting](https://kodi.wiki/view/Audio_troubleshooting) guide to passthrough and AC-3 transcoding.
- The local guest music queue draws on Room Mode in [MusicLounge Jukebox](https://forums.plex.tv/t/new-app-musiclounge-jukebox/942146) by [Earthmonkey](https://forums.plex.tv/u/Earthmonkey).
- Projector calibration draws on the upstream constant-image-height request [Plezy #863](https://github.com/edde746/plezy/issues/863) by [@thehomerepot](https://github.com/thehomerepot).

Pleazyng implemented these features independently. See the [attribution ledger](../../UPSTREAM_ATTRIBUTION.md).
