# Preferred subtitle provider fetch controls

Automatic preferred-language retrieval during playback startup now shares one
12-second wall-clock budget across provider search, download and catalog
discovery. Provider search is capped at six seconds and download at five;
catalog reads and polling use the remaining budget. A visible Cancel action
releases startup immediately.

Plex, Jellyfin and Emby provider search/download transports accept the active
abort controller. Catalog discovery uses existing non-cancellable client APIs,
but every awaited result is checked against the live attempt before it can be
used. Playback replacement, profile changes, shutdown, disabling automatic
downloads, and a manual subtitle selection retire the attempt. Retired results
cannot be merged into playback or select a subtitle.

The existing explicit-Off, server-selection, live-stream, offline, profile
subtitle-mode and already-selected-track guards remain in place. Attempts are
scoped to the active profile, item, source and preferred languages; the player
keeps at most 64 attempt keys. The subtitle track sheet shows progress and
no-result/error status. After a
terminal result, Search subtitles opens the normal provider picker for an
explicit retry.

Cancellation cannot undo a download request the server has already accepted.
The server may finish that side effect later. This client does not delete a
server-side subtitle, and an ambiguous newly attached stream remains available
for explicit selection rather than being guessed.
