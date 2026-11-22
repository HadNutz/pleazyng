# Upstream source attribution

- Open individual Plex and Jellyfin photos full-screen and browse nested photo albums with pagination. The viewer bounds decoded images and uses the profile navigator’s Back handling. [jmtagarro](https://github.com/jmtagarro) proposed [Plezy PR #3020](https://github.com/edde746/plezy/pull/3020).

- Allow the finish clock next to remaining time to be hidden independently on desktop, touch and remote controls. Existing users keep their visible finish clock. [jtlopezdev](https://github.com/jtlopezdev) proposed [Plezy PR #3070](https://github.com/edde746/plezy/pull/3070).

- Give long TV summaries the available width while keeping titles, metadata, actions and the fork’s directional layout in their existing columns. [smee2018](https://github.com/smee2018) proposed [Plezy PR #3087](https://github.com/edde746/plezy/pull/3087).

- Reconcile the macOS video layer with actual window visibility after PiP closes. Preserve explicitly hidden, sleeping and occluded states and restore playback activity only for visible playing video. [wthueb](https://github.com/wthueb) proposed [Plezy PR #3008](https://github.com/edde746/plezy/pull/3008).

- Allow users to withdraw their own pending film or TV request. The client rechecks the request, owner, title and edition before deleting the request record. Library files remain under the server administrator’s control. [wetpas](https://github.com/wetpas) proposed [Plezy PR #3111](https://github.com/edde746/plezy/pull/3111).

- Desktop users can select or reset the screenshot folder. macOS remembers the user-approved folder with a security-scoped bookmark, and mpv retains its Pictures default. [NoahBK](https://github.com/NoahBK) proposed [Plezy PR #3095](https://github.com/edde746/plezy/pull/3095).

- Prefer exact regional audio and subtitle matches before language-only and cross-region fallback, and carry regional preferences through Plex account settings and subtitle search with localized language names. [strata-scribe](https://github.com/strata-scribe) proposed [Plezy PR #3005](https://github.com/edde746/plezy/pull/3005).

- Allow authorized Plex owners to refresh one item. Cache invalidation and detail updates check the selected server, session and settled item ID. [denizt](https://github.com/denizt) proposed [Plezy PR #3118](https://github.com/edde746/plezy/pull/3118).

- Apple TV users can choose static Top Shelf artwork for every profile. The extension and publisher honor the device setting alongside existing PIN and profile restrictions. [veresvit](https://github.com/veresvit) proposed [Plezy PR #3092](https://github.com/edde746/plezy/pull/3092).

- Show a profile-scoped reconnect notice for permanently invalidated tracker sessions. Keep the encrypted vault and ordered credential writes, and clear the warning on sign-in or intentional disconnect. [NoahBK](https://github.com/NoahBK) proposed [Plezy PR #3058](https://github.com/edde746/plezy/pull/3058).

- Play ordered or shuffled video playlists from fork links while retaining server and active profile ownership and the existing music routes. [davidmarcantonio](https://github.com/davidmarcantonio) proposed [Plezy PR #3130](https://github.com/edde746/plezy/pull/3130).

- Applied upstream sentence casing to imported shortcuts and grouped all language variants in the existing fork picker. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/b5144834d19b695cb5e0334e3dfdfb820269b9cd) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Integrated 1,901 applicable European Portuguese translations and CLDR regional routing while preserving fork translations and the separate Brazilian catalog. [luismiguelopes](https://github.com/luismiguelopes) contributed [the original change](https://github.com/edde746/plezy/commit/88bd8467ff4051be3a25794ff95ccb31c8b27a01) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Build hosted iOS release IPAs on the Xcode 27 image and check the effective iOS SDK on both hosted and selected signing runners. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/36f9ae3e31f580c642640dc67e7686215fd054ae) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Use volume-specific reclaimable capacity near the storage floor on iOS and macOS, with bounded sampling and the existing guarded write and staging paths. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/18a6637ce2cf978dff30422252d524dd2c2fda4f) to upstream Plezy. Pleazyng integrated the behavior for this fork. The vendored implementation also adapts [edde746’s downloader commit](https://github.com/edde746/background_downloader/commit/4f361e91f3cb79b7e48486b6397e43974b6e0452).

- Read Plex’s live deletion capability from the server root and reject confirmation when the active authentication session changes during the request. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/ad4518e66efd2609ce2272811af624039d127f84) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Rearm a storage-stopped queue only once per explicit download request, skip blocked sync-rule passes, and keep in-flight retries from clearing the storage error. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/54f135fe46f1aed4edc36a04241152fc9cac7bf5) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Constrain long multi-server subtitles inside the compact library picker while preserving full library choices. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/e0a2a8e9f34872920d8a60394cc1bca9827f75d7) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Use a nonthrowing version resolver for room identity and wire metadata, preserving the Pleazyng client name and existing Jellyfin onboarding fallback. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/d78b6d806e3ebf60881999564def7cad969722b5) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Rasterize the Discover backdrop gradient while retaining the fork’s responsive artwork and theme stops. [a-j-jones](https://github.com/a-j-jones) contributed [the original change](https://github.com/edde746/plezy/commit/77f11b86f06a3cd7ec73072dfc9c60bb6c985eb5) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Avoid starting unused built-in mpv scripts on Android while keeping explicit video-core configuration overrides. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/4c3c25b8233bb887d7224b3844f3763a88b720c5) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Batch demuxer refills only for uncached app-owned downloads, respecting custom mpv options and resetting the property on subsequent opens. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/3bf8c2752739a83cb5038fef9287bd6aac7d1e19) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Prefer precise 50/59.94/60 Hz modes for matching 25/29.97/30 fps video while preserving the existing frame-rate setting and motion-generated output path. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/e883c3ca5e170c2d5810c98d68803c586a97a270) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Register the video-only external display scene on supported iOS 27 SDKs and preserve the older scene-delegate path. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/23778fade45fc046cdd77d274d501dd0a0643e07) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Keep the TV profile menu, Retry and sidebar reachable when Home has no server rows, including the fork’s cloud-only rail. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/8310991fa14f0cbac9c71cfb494d028d4314c7ff) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Prompt on resume when a TV hosts the companion remote, while allowing its connected or reconnecting controller to resume normally. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/5d5f03c00c82da91c86e900dbe931516262b23f9) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Reuse the registered Plex client when a server returns with the same authentication and profile scope, so active playback keeps reporting progress. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/b179440450941150da98623e3a4fe3d2aebe900e) to upstream Plezy. Pleazyng integrated the behavior for this fork.

- Retry sleeping Plex servers after profile binding and resume with bounded, profile-aware backoff. [edde746](https://github.com/edde746) contributed [the original change](https://github.com/edde746/plezy/commit/4640404ce3c79d3a73271392cc6d5d18ca8ebedc) to upstream Plezy. Pleazyng integrated the behavior for this fork.

This ledger credits upstream reports, feature requests, implementation sources, and project documentation that informed Pleazyng.

The linked people made their reports, suggestions, discussions, or code contributions to the upstream project. This is source credit only: it does not claim that they contributed directly to this fork, endorsed it, or participated in the fork integration. Fork maintainers adapted, integrated, or verified the resulting behavior separately.

The PR list comes from explicit “Squash of upstream” commit records and the selected November follow-up. The commit list covers follow-up changes that were sourced from upstream commits rather than PR records.

## M3U Web Picker

[Zachary Schmook (@zschmook)](https://github.com/zschmook) and contributors implemented the [v49 Xtream live-only catalog and capped M3U fallback](https://github.com/zschmook/m3u-web-picker/blob/8822e68538ac91ab25bf805a74fa6bacdc2b7897/src/core.py). Pleazyng independently implements live stream and category resolution, credential-safe playback paths and bounded fallback between a provider’s two formats.

[Zachary Schmook (@zschmook)](https://github.com/zschmook) and contributors established the [provider limits](https://github.com/zschmook/m3u-web-picker/blob/8822e68538ac91ab25bf805a74fa6bacdc2b7897/src/settings.py) and [channel-count validation](https://github.com/zschmook/m3u-web-picker/blob/8822e68538ac91ab25bf805a74fa6bacdc2b7897/src/core.py). Pleazyng independently implements these limits using its Dart importer and original boundary fixtures.

[M3U Web Picker v49](https://github.com/zschmook/m3u-web-picker/tree/8822e68538ac91ab25bf805a74fa6bacdc2b7897), created by [Zachary Schmook (@zschmook)](https://github.com/zschmook) and contributors, inspired Pleazyng's native local playlist import, provider and custom group selection, independent channel order, M3U/XMLTV export, interval-based guide merging, profile-owned backup-source selection and the native guide-based sports browser. The public U.S. preview lineup comes from [IPTV-org](https://github.com/iptv-org/iptv). Pleazyng implements these behaviors independently. Upstream's [provider operations](https://github.com/zschmook/m3u-web-picker/blob/8822e68538ac91ab25bf805a74fa6bacdc2b7897/api/providers.py) and [guide merge](https://github.com/zschmook/m3u-web-picker/blob/8822e68538ac91ab25bf805a74fa6bacdc2b7897/sports/guide.py) are the behavior references. Pleazyng’s on-device series scheduling also draws on the upstream [DVR series rules](https://github.com/zschmook/m3u-web-picker/blob/8822e68538ac91ab25bf805a74fa6bacdc2b7897/src/dvr.py). The [native feature status](docs/features/native-iptv-parity.md) records implemented and outstanding workflows.


## Watch Together room recovery

[@edde746](https://github.com/edde746) authored the upstream [OpenWatchParty Dart client](https://github.com/edde746/openwatchparty/tree/main/sdk/dart). Pleazyng vendors the Apache-2.0 client from the [1.1.0 release](https://pub.dev/packages/openwatchparty/versions/1.1.0) and extends its authenticated reconnect path to restore the original member after process loss. The package retains its upstream license.

## Media-file workflows and format documentation

- The retained live-buffer recording interaction draws on [TiVo’s viewer guide](https://www.tivo.com/assets/pdfs/accessibility/TiVo_VG_Complete.pdf).
- The two external-audio use cases draw on [Jellyfin’s movie/external-audio documentation](https://jellyfin.org/docs/general/server/media/movies/) and [RiffTrax’s playback guide](https://www.rifftrax.com/howto).
- CUE album interpretation draws on [Kodi’s CUE-sheet documentation](https://kodi.wiki/view/Cue_sheets).
- Authored comic frames follow the [ACBF specification maintained by the ACBF project](https://github.com/ACBF-Advanced-Comic-Book-Format/ACBF).
- [Plex’s multi-episode file naming guide](https://support.plex.tv/articles/naming-and-organizing-your-tv-show-files/) describes the shared-file data model addressed by episode-boundary mapping.

These are format-documentation and interaction credits. Pleazyng independently implemented its recording recovery, episode maps, folder relinking, audio attachment, CUE indexing, guided reader and rewind integration. See [the feature guide](docs/features/media-file-tools.md) for verified scope and native packaging status.

## Living-room playback and music

- HDR subtitle brightness draws on the OLED viewing problem addressed by [barnebyte’s PlexOledSubtitles](https://github.com/barnebyte/PlexOledSubtitles). Pleazyng adjusts playback rendering and keeps the subtitle file intact.
- Series rotation draws on [raykwonx’s next-unwatched shuffle request](https://forums.plex.tv/t/shuffle-play-my-shows-but-only-play-the-next-unwatched-episode-of-that-show/936507).
- Stereo channel selection addresses the [bilingual soundtrack use case reported by Plex viewers](https://www.reddit.com/r/PleX/comments/oqu872/).
- Cross-library reading lists draw on [Kavita’s CBL importer](https://wiki.kavitareader.com/guides/features/cbl-import/) and the [Komga reading-order discussion](https://github.com/gotson/komga/issues/1803).

These authors proposed the linked behaviors to their respective projects. Pleazyng independently implemented the features described below.

- Hardware Play on a focused poster draws on the upstream feature requests [Plezy #1510](https://github.com/edde746/plezy/issues/1510) by [@enchained](https://github.com/enchained) and [Plezy #3038](https://github.com/edde746/plezy/issues/3038) by [@fillilutten](https://github.com/fillilutten).
- The missing-episode prompt draws on the upstream feature request [Jellyfin Android TV #4566](https://github.com/jellyfin/jellyfin-androidtv/issues/4566) by [@hufforguk](https://github.com/hufforguk).
- Dolby Digital receiver output draws on the upstream feature request [Plezy #3054](https://github.com/edde746/plezy/issues/3054) by [@abaginski](https://github.com/abaginski) and the [Kodi audio troubleshooting](https://kodi.wiki/view/Audio_troubleshooting) guide to passthrough and AC-3 transcoding.
- The local guest music queue draws on Room Mode in [MusicLounge Jukebox](https://forums.plex.tv/t/new-app-musiclounge-jukebox/942146) by [Earthmonkey](https://forums.plex.tv/u/Earthmonkey).
- Projector calibration draws on the upstream constant-image-height request [Plezy #863](https://github.com/edde746/plezy/issues/863) by [@thehomerepot](https://github.com/thehomerepot).

- Extending an active sports recording draws on [gingie’s Channels DVR request](https://community.getchannels.com/t/extend-live-recordings/1789).
- Original dialogue selection draws on [@Altarentys’s Plezy request #3019](https://github.com/edde746/plezy/issues/3019).
- Per-issue comic spread correction draws on the pairing problem reported by [@fatherpanda in Kavita #4903](https://github.com/Kareadita/Kavita/issues/4903).
- Synchronized personal audio description takes inspiration from [GRETA by Greta & Starks Apps GmbH](https://apps.apple.com/ca/app/greta/id793892423). Pleazyng uses the listener’s own server file and embedded tracks.

## Credited Moonlight Android source

- [Moonlight Android commit `b48494cb`](https://github.com/moonlight-stream/moonlight-android/commit/b48494cb96bff23d8886c4775cc4f39a1075495d) — pinned receiver revision (v12.2), authored upstream by [@cgutman](https://github.com/cgutman). The author contributed this receiver implementation to the upstream Moonlight project. Pleazyng independently adapted its connection, decoder, audio-renderer, input lifecycle, and retained-surface recovery for a workspace surface; this record does not claim that the author contributed to, endorsed, or participated in Pleazyng.

## Credited dependency compatibility fix

- [AetherEngine commit `fa8cc48b`](https://github.com/superuser404notfound/AetherEngine/commit/fa8cc48b93a5b9c83367bf4fb3d731fb3862a177) / [issue #883](https://github.com/superuser404notfound/AetherEngine/issues/883) — “fix(build): the package compiles on Xcode 26.3 (Swift 6.2) again,” authored and contributed to AetherEngine upstream by [@superuser404notfound](https://github.com/superuser404notfound). Pleazyng independently backports the three upstream compatibility changes to its older pinned AetherEngine source during the locked Apple runtime build; this credit does not claim a direct contribution to Pleazyng.

## Credited Audiobookshelf feature request

- [Issue #260](https://github.com/advplyr/audiobookshelf-app/issues/260), “[iOS] Auto sleep timer,” opened upstream by [@GeorgeHahn](https://github.com/GeorgeHahn). GeorgeHahn suggested automatic sleep-timer activation during certain hours to the Audiobookshelf project. Pleazyng independently adapts that idea as a profile-scoped daily local bedtime for an active audiobook session with a ten-second fade; this record does not claim direct contribution, endorsement, or participation in Pleazyng.

## Credited Plezy pull requests

Pleazyng independently integrated or adapted these upstream PRs.

- [PR #1197](https://github.com/edde746/plezy/pull/1197) — “feat(downloads): add manual sync button for sync rules,” opened upstream by [@Darkmadda](https://github.com/Darkmadda). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #1199](https://github.com/edde746/plezy/pull/1199) — “feat(downloads): random episode selection + Custom Amount (Any),” opened upstream by [@Darkmadda](https://github.com/Darkmadda). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #1516](https://github.com/edde746/plezy/pull/1516) — “feat(libraries): show item count in browse toolbar,” opened upstream by [@RyanTheTechMan](https://github.com/RyanTheTechMan). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #1584](https://github.com/edde746/plezy/pull/1584) — “feat(player): add frame-by-frame navigation,” opened upstream by [@RyanTheTechMan](https://github.com/RyanTheTechMan). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #1757](https://github.com/edde746/plezy/pull/1757) — “feat(playlist): Add reliable repeat for video playlists,” opened upstream by [@UltimateInternet](https://github.com/UltimateInternet). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2091](https://github.com/edde746/plezy/pull/2091) — “Add Emby remote subtitle search and download flow,” opened upstream by [@Bockiii](https://github.com/Bockiii). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2248](https://github.com/edde746/plezy/pull/2248) — “feat(plex): Add local-only Plex server connection,” opened upstream by [@datacompboy](https://github.com/datacompboy). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2300](https://github.com/edde746/plezy/pull/2300) — “feat(livetv): add a program-aware Plex timeshift timeline,” opened upstream by [@nullroute77](https://github.com/nullroute77). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2347](https://github.com/edde746/plezy/pull/2347) — “feat(settings): live subtitle styling preview and an RGB picker mode,” opened upstream by [@infixlabs](https://github.com/infixlabs). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2376](https://github.com/edde746/plezy/pull/2376) — “feat(downloads): show storage used and per-item download sizes,” opened upstream by [@sneakyimp1](https://github.com/sneakyimp1). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2483](https://github.com/edde746/plezy/pull/2483) — “feat(plex): play the server-configured pre-roll before movies (closes #970),” opened upstream by [@torp93](https://github.com/torp93). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2563](https://github.com/edde746/plezy/pull/2563) — “feat(plex): label versions in the picker and remember the pick across episodes,” opened upstream by [@aZuiZui](https://github.com/aZuiZui). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2596](https://github.com/edde746/plezy/pull/2596) — “feat(detail): play Plex, Jellyfin and Emby theme songs on detail pages,” opened upstream by [@crowquillx](https://github.com/crowquillx). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2597](https://github.com/edde746/plezy/pull/2597) — “feat(library): bulk select items and update watch state,” opened upstream by [@sneedster](https://github.com/sneedster). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2601](https://github.com/edde746/plezy/pull/2601) — “feat(player): add horizontal swipe-to-seek gesture on touch devices,” opened upstream by [@maf2010-boop](https://github.com/maf2010-boop). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2681](https://github.com/edde746/plezy/pull/2681) — “feat(deep-links): plezy://watch links to play a Plex show or movie,” opened upstream by [@razzamatazm](https://github.com/razzamatazm). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2725](https://github.com/edde746/plezy/pull/2725) — “Add filters to the Plex watchlist,” opened upstream by [@Supergamer1337](https://github.com/Supergamer1337). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2738](https://github.com/edde746/plezy/pull/2738) — “feat(ios): return Outplayer, Infuse and VLC to Plezy and sync their progress,” opened upstream by [@dvitjuks](https://github.com/dvitjuks). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2740](https://github.com/edde746/plezy/pull/2740) — “Add custom MDBList lists to Explore,” opened upstream by [@Adaptabull](https://github.com/Adaptabull). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2762](https://github.com/edde746/plezy/pull/2762) — “feat(detail): show directors in the cast strip and open their person page,” opened upstream by [@jpdexter101-lang](https://github.com/jpdexter101-lang). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2797](https://github.com/edde746/plezy/pull/2797) — “feat(player): add a Buffer Size setting for mpv and ExoPlayer,” opened upstream by [@BBergle](https://github.com/BBergle). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2811](https://github.com/edde746/plezy/pull/2811) — “feat(search): show Seerr titles missing from the server with a Request action,” opened upstream by [@MansiVisuals](https://github.com/MansiVisuals). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2824](https://github.com/edde746/plezy/pull/2824) — “feat(hotkeys): add subtitle delay increase/decrease shortcuts,” opened upstream by [@Rukko](https://github.com/Rukko). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2898](https://github.com/edde746/plezy/pull/2898) — “fix: Gate Plex deletes on server capability #2897,” opened upstream by [@primetime43](https://github.com/primetime43). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2938](https://github.com/edde746/plezy/pull/2938) — “fix(downloads): stop sync rules re-arming the queue after a storage refusal,” opened upstream by [@moust4ki](https://github.com/moust4ki). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2960](https://github.com/edde746/plezy/pull/2960) — “fix(plex): negotiate the selected direct-play version before opening,” opened upstream by [@nrlcode](https://github.com/nrlcode). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2971](https://github.com/edde746/plezy/pull/2971) — “feat: add PLEZY_FORCE_HDR opt-in for HDR passthrough,” opened upstream by [@Hermes-howly](https://github.com/Hermes-howly). Pleazyng independently integrated or adapted the upstream contribution.

## Credited Plezy commits

These upstream commits supplied additional implementation ideas or code to the November follow-up.

- [commit 02eeba6972](https://github.com/edde746/plezy/commit/02eeba69723b33f28e6b8ae9dab2ce1c02a1c3cd) — “fix(profiles): keep PIN-protected profiles off the TV home screen shelf while asking for a profile on open,” contributed upstream by [@edde746](https://github.com/edde746). Pleazyng independently adapts the publication policy, serialized shelf clearing, and resume notification so protected-profile Continue Watching remains hidden until the app no longer requires startup profile selection. The upstream author contributed this change to Plezy; this credit does not claim direct contribution to, endorsement of, or participation in Pleazyng.

- [commit 408da1ab83](https://github.com/edde746/plezy/commit/408da1ab83b552e8b155aef7dd5f3e4d6892d91b) for [issue #3022](https://github.com/edde746/plezy/issues/3022) — “fix(player): keep the remote working when a reload unmounts the focused control,” contributed upstream by [@edde746](https://github.com/edde746). Pleazyng independently adapts the focus handoff and restores Play/Pause only when an in-place reload removed the focused control, preserving the fork's keyboard-mode and route guards. The upstream author contributed this fix to Plezy; this credit does not claim direct contribution to, endorsement of, or participation in Pleazyng.

- [commit `847842c3d0`](https://github.com/edde746/plezy/commit/847842c3d075b56d686409850e12fa1cca0b19d9) — “perf(player): give mpv a constant title on iOS and tvOS (#3032),” authored upstream by [@edde746](https://github.com/edde746). The upstream author contributed the performance fix to Plezy. Pleazyng independently adapted the constant title for iOS/tvOS mpv contexts and added platform contract coverage; the upstream bench-app CPU result is not claimed as measured in Pleazyng.

- [commit `80c562ff06`](https://github.com/edde746/plezy/commit/80c562ff06db237b48592a89efb0f0b7baeb0e10) — “fix(downloads): stop the free-space guard capping desktop download speed (#2967),” authored upstream by [@edde746](https://github.com/edde746). Pleazyng independently adapted the upstream change.
- [commit `0ef47f2711`](https://github.com/edde746/plezy/commit/0ef47f2711ecb5ff30089831410b6f29b580cdcb) — “fix(tv): trigger list tile long-press from D-pad hold-select (#2964),” authored upstream by [@adamsparsons](https://github.com/adamsparsons). Pleazyng independently adapted the upstream change.
- [commit `d192a726b8`](https://github.com/edde746/plezy/commit/d192a726b8a8dd512d648f5cce9d568508d3ecd3) — “fix(downloads): exclude downloaded media from iCloud Backup on iOS,” authored upstream by [@edde746](https://github.com/edde746). Pleazyng independently adapted the upstream change.
- [commit `a597bcbe`](https://github.com/edde746/plezy/commit/a597bcbee228e1f519b5f2a527bc239981fd0672) — “fix(search): rank an artist's albums above titles that merely contain the artist,” authored upstream by [@edde746](https://github.com/edde746). The upstream author contributed this ranking fix to Plezy. Pleazyng independently adapts the stronger parent-title weight only for album rows, preserving track and other media ranking, and verifies the result separately; this does not claim direct contribution, endorsement, or participation in Pleazyng.
- [commit `a4f1b4f313`](https://github.com/edde746/plezy/commit/a4f1b4f313ee166afa0e0339ff7c1ebab7dc1bd6) and [issue #3062](https://github.com/edde746/plezy/issues/3062) — “fix(player): strip every Samsung HDR10+ message before the Fire TV DV decoder,” contributed upstream by [@edde746](https://github.com/edde746). Pleazyng independently adapted the Android HEVC SEI match to cover Samsung application-4 messages across oriented codes and application versions while retaining complete-header checks and preserving unrelated or truncated SEI data. This source credit does not claim direct contribution to or endorsement of Pleazyng.
- [commits `8cda18705d`](https://github.com/edde746/plezy/commit/8cda18705d99ea3b394f883600aa19ce4d1522c7) and [`ca916ebb24`](https://github.com/edde746/plezy/commit/ca916ebb2470166f4e0d2bc884e424af698e38f4), for [issue #3016](https://github.com/edde746/plezy/issues/3016), authored upstream by [@edde746](https://github.com/edde746). The author contributed the same-turn PiP controller-settling fix and Live TV auto-PiP setup to Plezy. Pleazyng independently adapted both changes and added focused Swift and live-player regression coverage; this credit does not claim direct contribution to, endorsement, or participation in Pleazyng.
- [commit `10bcdf38f3`](https://github.com/edde746/plezy/commit/10bcdf38f327ecbdaef4896b96916ac846a0db64) for [issue #3014](https://github.com/edde746/plezy/issues/3014), authored upstream by [@edde746](https://github.com/edde746). The author contributed the in-place Plex Home profile switch access re-probe to Plezy. Pleazyng independently adapts the probe to changed client/auth-session identity and records refused probes to avoid repeating unrelated checks; this does not claim direct contribution to, endorsement, or participation in Pleazyng.
- [commit `8916000299`](https://github.com/edde746/plezy/commit/8916000299dc0106614deede5ca7476d714984c7), authored upstream by [@edde746](https://github.com/edde746). The author contributed the empty-page pagination stop to Plezy. Pleazyng independently adapts the offset handling, prunes cached entries beyond the end, and fetches from the contiguous loaded prefix; this credit does not claim direct contribution to, endorsement, or participation in Pleazyng.

## Planned or not-yet-shipped upstream ideas

These upstream reports informed Pleazyng’s maintained subtitle plan. They are
credited as idea sources and are not presented as completed Pleazyng features.

- [issue #689](https://github.com/edde746/plezy/issues/689) — “Add subtitle styling into player,” opened upstream by [@ayydaz](https://github.com/ayydaz). Pleazyng’s subtitle plan references this upstream idea; implementation status remains separate.
- [issue #1442](https://github.com/edde746/plezy/issues/1442) — “Subtitle Size and Position Settings Are Ignored in Some Cases,” opened upstream by [@Shasoosh](https://github.com/Shasoosh). Pleazyng’s subtitle plan references this upstream report; implementation status remains separate.

## Additional feature requests and proposals

These records were already referenced by the README feature history. Their
titles, source types and upstream authors were verified on 2026-11-09. They
record related ideas, reports and proposals, including closed or declined ones;
they do not assert that every requested behavior shipped or that a proposal
was merged upstream. Pleazyng independently adapted or reviewed the relevant
behavior. The linked feature guides remain authoritative for implementation
and qualification status. In particular, native Plex Companion control, full
per-library track preferences, delayed-deletion policies and alternate intro
providers must not be inferred from the source credit alone.

### Downloads and offline

- [issue #1145](https://github.com/edde746/plezy/issues/1145) by [@nikwotton](https://github.com/nikwotton) — Downloads Quality
- [issue #1413](https://github.com/edde746/plezy/issues/1413) by [@coyodi](https://github.com/coyodi) — Setting to automatically delete orphaned downloads
- [PR #1847](https://github.com/edde746/plezy/pull/1847) by [@nikwotton](https://github.com/nikwotton) — Add configurable Plex download quality
- [issue #1978](https://github.com/edde746/plezy/issues/1978) by [@Poag](https://github.com/Poag) — Auto download episodes on "continue watching" shelf
- [issue #2181](https://github.com/edde746/plezy/issues/2181) by [@andperse](https://github.com/andperse) — delayed delete on watch
- [issue #2206](https://github.com/edde746/plezy/issues/2206) by [@burntcookie90](https://github.com/burntcookie90) — Allow sync rules to specify quality
- [issue #1447](https://github.com/edde746/plezy/issues/1447) by [@devildant](https://github.com/devildant) — Add an offline local access mode with manually configured Plex server address
- [issue #1721](https://github.com/edde746/plezy/issues/1721) by [@marcweigert2020](https://github.com/marcweigert2020) — Download playlist to use offline, or at least enable offline queueing of downloaded music.
- [issue #2600](https://github.com/edde746/plezy/issues/2600) by [@jonandeva](https://github.com/jonandeva) — Offline Playlist

### Profiles and privacy

- [issue #1924](https://github.com/edde746/plezy/issues/1924) by [@jhaffey2](https://github.com/jhaffey2) — Require authentication before deleting downloaded media
- [issue #2514](https://github.com/edde746/plezy/issues/2514) by [@trevorswanson](https://github.com/trevorswanson) — Feature Request: Disable Explore tab per profile

### Audio and subtitle selection

- [issue #84](https://github.com/edde746/plezy/issues/84) by [@heartdeadz](https://github.com/heartdeadz) — [Feature Request]Let me choose audio track / subs BEFORE starting the video. ( like plex's native player )
- [issue #1758](https://github.com/edde746/plezy/issues/1758) by [@tr3bag](https://github.com/tr3bag) — Automatically download and select subtitles in a preferred language
- [PR #1956](https://github.com/edde746/plezy/pull/1956) by [@basymbhamani](https://github.com/basymbhamani) — fix(player): remember subtitle and audio sync offsets per media item
- [issue #2116](https://github.com/edde746/plezy/issues/2116) by [@pjakessonVS](https://github.com/pjakessonVS) — Preserve subtitle language track between episodes
- [issue #2182](https://github.com/edde746/plezy/issues/2182) by [@cthulhu7747](https://github.com/cthulhu7747) — Add Option to Choose the Audio Track Prior to Playback
- [PR #2346](https://github.com/edde746/plezy/pull/2346) by [@infixlabs](https://github.com/infixlabs) — feat(subtitles): opt-in always-on subtitles and Plex auto-download
- [issue #2382](https://github.com/edde746/plezy/issues/2382) by [@uaverb](https://github.com/uaverb) — Per-series audio track and subtitle preference override
- [issue #2792](https://github.com/edde746/plezy/issues/2792) by [@calmcacil](https://github.com/calmcacil) — Per-library overrides for preferred audio language and subtitles

### Subtitle controls and reports

- [issue #95](https://github.com/edde746/plezy/issues/95) by [@sangju41](https://github.com/sangju41) — [Feature Request] Subtitle font change
- [issue #2174](https://github.com/edde746/plezy/issues/2174) by [@saakethkaashyap](https://github.com/saakethkaashyap) — In-Player Subtitle Position and Size Controls
- [issue #1431](https://github.com/edde746/plezy/issues/1431) by [@Kuboczoch](https://github.com/Kuboczoch) — [Feature Request] Add option to load subtitles from a local file

### Playback, music and intro controls

- [issue #1985](https://github.com/edde746/plezy/issues/1985) by [@balupton](https://github.com/balupton) — Feature Request: repeat-one, repeat-all
- [issue #970](https://github.com/edde746/plezy/issues/970) by [@bart7782](https://github.com/bart7782) — Plex Preroll support
- [PR #2271](https://github.com/edde746/plezy/pull/2271) by [@Bergasha](https://github.com/Bergasha) — feat(player): play a random preroll clip before movies
- [issue #791](https://github.com/edde746/plezy/issues/791) by [@JunaidDawood](https://github.com/JunaidDawood) — TV Theme Music (Support Local Media Assets)
- [PR #2170](https://github.com/edde746/plezy/pull/2170) by [@kvart714](https://github.com/kvart714) — feat(plex): play theme music on home spotlights
- [issue #367](https://github.com/edde746/plezy/issues/367) by [@WoofGrrrr](https://github.com/WoofGrrrr) — Background play
- [PR #2292](https://github.com/edde746/plezy/pull/2292) by [@whereareiam](https://github.com/whereareiam) — feat(audio): add a device-local equalizer
- [issue #2064](https://github.com/edde746/plezy/issues/2064) by [@Kenshu0](https://github.com/Kenshu0) — Separate Quality options for remote and local streaming
- [issue #389](https://github.com/edde746/plezy/issues/389) by [@brumatheus99](https://github.com/brumatheus99) — Support for TheIntroDB API for Skip Intro/Outro Management
- [issue #1110](https://github.com/edde746/plezy/issues/1110) by [@Kida-Tech](https://github.com/Kida-Tech) — Anime skip
- [PR #1886](https://github.com/edde746/plezy/pull/1886) by [@stuntsnakee](https://github.com/stuntsnakee) — feat: Add TheIntroDB service integration for intro & recap markers

### Browsing, requests and library actions

- [issue #1517](https://github.com/edde746/plezy/issues/1517) by [@R3iniX](https://github.com/R3iniX) — Search by Actor/Director
- [issue #2368](https://github.com/edde746/plezy/issues/2368) by [@maxpowr1983-boop](https://github.com/maxpowr1983-boop) — Search for "artist/producer..."
- [issue #1561](https://github.com/edde746/plezy/issues/1561) by [@Kainton](https://github.com/Kainton) — Shuffle library
- [issue #2741](https://github.com/edde746/plezy/issues/2741) by [@fallenbuddhist](https://github.com/fallenbuddhist) — Random/Shuffle Movie Library: Plex app has this
- [issue #2757](https://github.com/edde746/plezy/issues/2757) by [@kncowans](https://github.com/kncowans) — Add the ability to Shuffle the Entire Music Library
- [issue #2671](https://github.com/edde746/plezy/issues/2671) by [@sjiawjbssj](https://github.com/sjiawjbssj) — Show "ends at" on details screen

### Home and library presentation

- [issue #1652](https://github.com/edde746/plezy/issues/1652) by [@jpdexter101-lang](https://github.com/jpdexter101-lang) — Home Screen: Merge Sections Across Multiple Libraries
- [PR #2203](https://github.com/edde746/plezy/pull/2203) by [@jpdexter101-lang](https://github.com/jpdexter101-lang) — configurable home rows: merge libraries, collection rows (#1652)
- [PR #2498](https://github.com/edde746/plezy/pull/2498) by [@PilaScat](https://github.com/PilaScat) — feat(libraries): optionally hide empty libraries
- [issue #2690](https://github.com/edde746/plezy/issues/2690) by [@OutragedG](https://github.com/OutragedG) — [Feature Request] Split next up & continue watching
- [issue #2701](https://github.com/edde746/plezy/issues/2701) by [@SilverRings11](https://github.com/SilverRings11) — Option to disable highlighted background fanart/backdrop
- [PR #2723](https://github.com/edde746/plezy/pull/2723) by [@mpalermo73](https://github.com/mpalermo73) — Make the Continue Watching row limit configurable
- [issue #2784](https://github.com/edde746/plezy/issues/2784) by [@oliwarner](https://github.com/oliwarner) — Allow hiding Hero on Android TV
- [PR #1529](https://github.com/edde746/plezy/pull/1529) by [@8bitgentleman](https://github.com/8bitgentleman) — Add a setting to choose which servers appear on Home

### Server choice and media links

- [issue #591](https://github.com/edde746/plezy/issues/591) by [@xXSalamanderXx](https://github.com/xXSalamanderXx) — Select Preferred Server / Choose Default Server / Switch Between Plex Servers
- [issue #2720](https://github.com/edde746/plezy/issues/2720) by [@wraeuk](https://github.com/wraeuk) — Set favourite plex server(s), lazyload the others

### Cast, alerts, screensaver and automation

- [issue #126](https://github.com/edde746/plezy/issues/126) by [@benfrussell](https://github.com/benfrussell) — Google Cast support
- [issue #1146](https://github.com/edde746/plezy/issues/1146) by [@SquadCraftFTW](https://github.com/SquadCraftFTW) — Notification for new episode (from official Plex app)
- [issue #401](https://github.com/edde746/plezy/issues/401) by [@C2fifield](https://github.com/C2fifield) — Feature Request: Content Screensaver
- [issue #823](https://github.com/edde746/plezy/issues/823) by [@Deathbot64](https://github.com/Deathbot64) — Control the player from external sources like Home Assistant.
- [issue #1996](https://github.com/edde746/plezy/issues/1996) by [@npike](https://github.com/npike) — Android - Intents for automation?

### Settings and diagnostics

- [PR #2496](https://github.com/edde746/plezy/pull/2496) by [@PilaScat](https://github.com/PilaScat) — feat(logs): save logs to a file
- [issue #1795](https://github.com/edde746/plezy/issues/1795) by [@ckravig](https://github.com/ckravig) — Plezy Settings Cloud Backup

## Feature inventory reference

- [Upstream README snapshot](https://github.com/edde746/plezy/blob/738e18fdc552ace910dedabf6e689ab74e1dae58/README.md), pinned at [commit `738e18fdc5`](https://github.com/edde746/plezy/commit/738e18fdc552ace910dedabf6e689ab74e1dae58), authored upstream by [@edde746](https://github.com/edde746). Pleazyng independently verified the inherited feature baseline against this upstream project snapshot for the [Plex/Plezy/Pleazyng comparison](docs/FEATURE_COMPARISON.md). This credits the upstream inventory and snapshot author; the comparison does not attribute every inherited feature to one person or claim direct participation in this fork.

## Feature documentation source footers

Feature guides link the relevant upstream records directly and link back to
this ledger for source disposition. The author links credit work or suggestions
made to Plezy; Pleazyng adaptation remains independent. A related feature
request is context, not proof that its entire scope is implemented.

_Attribution ledger refreshed 2026-11-09; see the linked per-record dispositions below._

## Music media-session integration

The music/car integration vendors the already pinned [edde746/media_controls commit a27208e](https://github.com/edde746/media_controls/commit/a27208e641790029ac54d825b97508575caee1a7), maintained by [@edde746](https://github.com/edde746), retaining its license and existing platform implementations. Pleazyng independently adds the music browser bridge. The sonic request contract was checked against [Python-PlexAPI](https://github.com/pkkid/python-plexapi)'s published `nearest` and `computePath` client implementation; no Python source was copied. Native qualification and full parity remain tracked in `docs/plezyng/music/STATUS.md`.

## Reviewed upstream synchronization — 2026-11-09

These authors contributed the changes to upstream Plezy; Pleazyng independently
adapted and verified the behavior. This does not imply direct contribution or
endorsement of this fork.

- [Shared Android Media3 FFmpeg decoder](https://github.com/edde746/plezy/commit/54a002f9b7271603d6eecba16079990dd1f83d28), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently integrated the Media3 JNI decoder and renderer with the FFmpeg libraries packaged by its Android mpv engine. The fork now resets TrueHD through FFmpeg's registered flush callback and checks the pinned FFmpeg 9 ABI.

- [Companion remote reconnect state](https://github.com/edde746/plezy/commit/e871d095171855914d8f0634b3507a80e67bedce), upstream commit by [@edde746](https://github.com/edde746): retain selected controls and scroll position during reconnect.
- [Covered-route focus handoff](https://github.com/edde746/plezy/commit/5076836a5dbb2f54b8316fdcb9d94330c1ddbf01), upstream commit by [@edde746](https://github.com/edde746): let an unfocused page above the main screen receive remote navigation.
- [Non-atomic RSS sampling regression](https://github.com/edde746/plezy/commit/55ef954e23bbcb6fac81b15a84ff7442c87c6d58), upstream commit by [@edde746](https://github.com/edde746): test independent OS counters without an unsupported ordering requirement.

- [Newly-online Continue Watching version copies](https://github.com/edde746/plezy/commit/119ce59def9eacef8ac70e2b8c0d7fdfe771e0a4), upstream commit by [@edde746](https://github.com/edde746): independently adapted to the fork, retaining its profile/transport and failed-restore retry guards.

- [Continue Watching artwork reconciliation](https://github.com/edde746/plezy/commit/f2985a7b06b1190507946cde824779880d7d2af8), upstream commit by [@edde746](https://github.com/edde746): independently adapted to the fork, retaining its profile/transport and failed-restore retry guards.

- [Late display-switch restoration](https://github.com/edde746/plezy/commit/ddcfda3c4e349ec315f1c5496a5a0e95128b6997), upstream commit by [@edde746](https://github.com/edde746): independently adapted to the fork, retaining its profile/transport and failed-restore retry guards.

- [Artwork resize debounce and resolution retention](https://github.com/edde746/plezy/commit/38c48f14ac4107cc94b2ab2f41444f0448d64da0), contributed upstream by [@strata-scribe](https://github.com/strata-scribe): Pleazyng independently integrated and verified this change, preserving its existing artwork and session behavior.

- [Watch Together guest version switching](https://github.com/edde746/plezy/commit/6c87210c6162ecaf5e9a77560353a7948e1e93bd), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently integrated and verified this change, preserving its existing artwork and session behavior.

- [Skia selection without Vulkan 1.1](https://github.com/edde746/plezy/commit/d2424018297a00fe1f8bc97ef2bb207f6a515499), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently integrated and verified this change, preserving its existing artwork and session behavior.

- [Theme-derived focus fills](https://github.com/edde746/plezy/commit/4eabc30c804c9e6869a8c48fa1d6d174f7d36fbb), upstream commit by [@edde746](https://github.com/edde746): independently adapted while preserving Pleazyng palettes, rasterized gradients and custom player chrome.

- [Light-theme scrim color interpolation](https://github.com/edde746/plezy/commit/13426a00c034097b2301967f281adbfd58381598), upstream commit by [@edde746](https://github.com/edde746): independently adapted while preserving Pleazyng palettes, rasterized gradients and custom player chrome.

- [Transparent status-bar styling](https://github.com/edde746/plezy/commit/c7f86ab85fbc2c3497676744b6b5b0b6907887d7), upstream commit by [@edde746](https://github.com/edde746): independently adapted while preserving Pleazyng palettes, rasterized gradients and custom player chrome.

- [Scoped custom video zoom](https://github.com/edde746/plezy/commit/e90973fba999838fbeb9d14b8aa8226130918be8), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted zoom persistence and finite bounds, retaining profile-keyed resets and agent validation. Zoom remains session-only by default.

- [Hold playback beneath the resume profile picker](https://github.com/edde746/plezy/commit/9fe138aba39414e38099cc17cfd4296f47059778), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted pause the covered player and refuse native, media-session, Watch Together and Play Next resume intents until profile selection finishes, preserving Automotive restrictions and active PiP.

- [Windows pending-resize engine correction](https://github.com/edde746/plezy/commit/90b7ccca68cffcfe51fc8994c3463fcbf769ec18), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted pin the checksum-verified +2 engine for the existing Flutter ABI, retaining DirectComposition and x64/arm64 cache layouts; native Windows qualification remains separate.

- [Stable package publication metadata guard](https://github.com/edde746/plezy/commit/1dd75b3e5e95913cdaa5b8c22911490e72dfb7c5), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted reject GitHub pre-releases even when their tags look like stable versions, retaining manual publication and the fork publisher.

- [System certificate authorities for GitHub asset redirects](https://github.com/edde746/plezy/commit/cbd9205f2cef71973dd7cadf568477c448cb3787), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted retain system-only certificate trust through githubusercontent.com redirects on Android and dart:io, without enabling the upstream anime-feed migration.

- [Switch Android mpv display mode before decoder creation](https://github.com/edde746/plezy/commit/c577edda5cdf4b0a0c3d5dd0d543e432c5bed0d8), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted hold VOD decoding at demux preload while display matching settles, bound and cancel stale holds, reject predecessor-player tokens, and retain first-frame Live TV matching, Dolby/FEL routing and motion-processing output targets.

- [Adaptive fold and vertical-bar mobile layout](https://github.com/edde746/plezy/commit/b4192d6f355921aa9dbdd89b000012e7c4496fa7), contributed upstream by [@v-vincere](https://github.com/v-vincere): Pleazyng independently adapted place navigation in the system bar, keep hosted sheets on one side of a fold and retain player ownership across route replacement; preserve the fork’s scrollable navigation and system-bar styling. The fork extends that foundation with shared pane geometry, retained playback and detail navigation, reader spreads, compact music controls, and SDK verification.

- [Sheet safe areas beside a vertical system bar](https://github.com/edde746/plezy/commit/04ec8506c78dc29b4dfc18f751943fb6ecb89eec), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted remove the opposite status-bar inset and align hosted and modal sheets with the mobile content edge while retaining keyboard insets and back handling.

- [Actionable tvOS trailers and external links](https://github.com/edde746/plezy/commit/16d5b404cb14163a776b701265e55b6f66cdfc34), contributed upstream by [@moust4ki](https://github.com/moust4ki): Pleazyng independently adapted play library trailers internally, offer YouTube handoff only when its app is installed, hide unsupported browser links and report failed handoffs; preserve Seerr actions and block unsafe provider URI schemes.

- [More reliable iOS speed-change qualification](https://github.com/edde746/plezy/commit/48926474e863b8079558e41cb1d4776439ed1555), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted test the immediate position jump and the steady rate after output restarts, retaining the fork’s simulator limitation and deterministic flush-order coverage.

- [AppImage update metadata and verified zsync sidecars](https://github.com/edde746/plezy/commit/d832b4212ceabc68bfee6785177f40bd2a724723), contributed upstream by [@nataloko](https://github.com/nataloko): Pleazyng independently adapted build x64 AppImages with fork-specific update information, verify control-file names, blocks and digests, checksum and attest both artifacts, and preserve immutable legacy images without update metadata.

## Flutter security engine build (2026-11-09)

The security-engine builder uses [edde746/flutter-plezy](https://github.com/edde746/flutter-plezy/tree/06654fe6ff3fff67fdaa74e2a7c41ecbbc90bee2)'s existing Windows DirectComposition and resize patch series and build driver at immutable revision `06654fe6ff3fff67fdaa74e2a7c41ecbbc90bee2`. It applies those patches to Flutter 3.47.8 (`737ba8f885dc774b53b442759999a312c9461e4e`) with the upstream fixed Dart dependency for [GHSA-frr6-h895-5pxp](https://github.com/dart-lang/sdk/security/advisories/GHSA-frr6-h895-5pxp). The patch-source license and source revision receipt accompany the resulting archives. The orchestration script is original Pleazyng code. Built artifacts must pass verification before replacing the existing Windows engine pin.


## Complete reviewed commit dispositions — Plezy 2.26

The [64-commit review](docs/maintainers/upstream-sync-2026-11-09.md) and
[machine-readable records](docs/maintainers/upstream-sync-2026-11-09.json) link
every originating upstream commit and its upstream author's GitHub account.
Those people contributed to upstream Plezy; Pleazyng independently adapted or
verified the scope recorded there. Excluded and retained records remain review
sources, without claims of direct contribution to or endorsement of this fork.

### Native compatibility integration — packaged and verified

- [Upstream 63f8cd5a05](https://github.com/edde746/plezy/commit/63f8cd5a054e2ecc5c28dd30fe8066f4356a10c4) by [@edde746](https://github.com/edde746): Independently adapted Amlogic transparent letterboxing with the Amazon exception. Normal Android engine 6168c50b5c17 and AAR 82ace919fd97 include the native option; all four ABIs were built and inspected, and API-36 Android TV JNI read/write and playback lifecycle checks passed. Physical Dolby Vision black levels remain hardware-specific qualification.
- [Upstream 2e1654b316](https://github.com/edde746/plezy/commit/2e1654b316150f59cbc4774602ed4f02a3515527) by [@edde746](https://github.com/edde746): Independently enabled Apple MPV shader presets and ambient lighting with normal Libmpv 93fdd133cea1. All six Apple platform groups were built, every packaged architecture passed the real-stage check, and iOS/tvOS consumers linked. Real Mac M4 playback exercised hardware decoding, GLSL, stretched output and shutdown; the discovered embedded Cocoa initialization deadlock was fixed. Dolby Vision and other documented runtime exclusions remain explicit.
- [Upstream 6cc283a7da](https://github.com/edde746/plezy/commit/6cc283a7da3d75ed90ec232dd7f5da1f25681b4f) by [@edde746](https://github.com/edde746): Independently adapted the one-refresh subtitle offset for Amlogic and MediaTek TV devices after integrating early queueing and per-video-frame repetition into the normal Android/FEL engine. Scheduler, unchanged-content, rebind and runtime JNI range checks passed. Phones and unknown SoCs retain zero delay; physical TV scanout timing remains hardware-specific qualification.

The fork's native asset pins, normal FEL/HDR/NPU components and runtime opt-ins
remain intact. Upstream ancestry alone is not proof that an implementation is
active in the fork's package.

The Windows patch-source/build-driver record above originates at
[commit 06654fe6](https://github.com/edde746/flutter-plezy/commit/06654fe6ff3fff67fdaa74e2a7c41ecbbc90bee2),
contributed to the upstream engine project by [@edde746](https://github.com/edde746).
Pleazyng independently reuses that source in its security-engine orchestration;
artifact verification remains distinct from source credit.

The corresponding native changes were contributed to upstream mpv-build by
[@edde746](https://github.com/edde746):
[Apple GLSL stage](https://github.com/edde746/mpv-build/commit/2b23527),
[stretch geometry](https://github.com/edde746/mpv-build/commit/9929c5e),
[letterbox option](https://github.com/edde746/mpv-build/commit/bc87af7),
[early subtitle queue](https://github.com/edde746/mpv-build/commit/98452a9)
and [per-frame subtitle repetition](https://github.com/edde746/mpv-build/commit/8958474).
Pleazyng independently integrated and verified them with its existing normal
FEL/HDR/neural packages. This does not imply participation in or endorsement
of this fork. See the [playback compositor guide](docs/plezyng/playback-compositor.md).
