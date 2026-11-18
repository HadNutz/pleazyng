# Recordings, editions, albums and comic panels

## Keep a manual recording when stopping fails

Manual local IPTV captures keep their own partial media if closing the writer,
reserving the destination, or saving its final location fails. An existing file
with the same destination name is preserved. In **Live TV → Recordings**, an
interrupted capture with surviving bytes can be played. Restart recovery checks
the app-owned partial file as well as the journaled destination.

## Keep the buffered part of a live programme

On mpv local IPTV playback, press **Record** while an eligible seekable buffer
is available. Choose **Keep from [time]** or **Record from now**. The first option
starts at the later of the programme start and the retained buffer start. The
buffer is checked again after the choice in case it has advanced.

A single asynchronous demuxer dump remuxes the retained packets and continues
recording live packets. It does not open another provider stream. Stopping the
recording flushes that same writer. Channel changes and shutdown finish it
before replacing the player. This requires a native build with the MPEG-TS
recording muxer; native TV engines without this packet buffer do not offer it.

## Start the right episode inside a shared file

For a direct-play, single-file multi-episode edition on mpv, explicitly labeled
**Episode 2** or **S01E02: …** chapters supply episode boundaries. For files
without those labels, pause at the boundary and open **Tracks → Episode [n]
starts here**. Choose the episode number. The saved map belongs to the current
profile and the exact server file, size and duration.

Mapped episodes have their own playback duration, seek clock and watched
credit. Chapter/skip controls, scrub previews and system media-control duration
use that same episode clock. Next/previous navigation visits a mapped sibling in the same file.
Unequal runtimes work without dividing the total duration into equal pieces.
Original-quality downloads of separately queued sibling episodes reuse the same complete file when server path, size and duration match. Each episode retains its own row and progress, and deleting one preserves the bytes while another references them.

An incomplete map does not invent the missing boundaries. Unmapped editions
keep the existing whole-file behavior. Server transcodes and stacked editions
continue to use their existing timelines.

## Locate a moved local folder

Edit a local source and choose **Locate moved folder**. Select the old indexed
folder and its new location. Review the candidate list, then save the source.
The operation keeps the original entry ids, retaining reading history, notes,
bookmarks and manual comic-list matches.

A candidate with a downloaded copy is selected automatically only when the
complete bytes match. Same-name/same-size candidates without those bytes need
explicit review. Different bytes are excluded. Only verified copies retain the
old offline revision. A manually confirmed match carries its reading position,
bookmarks and comic settings to the new file while keeping offline content
verification independent. Moving the entire root updates the source location.
Moving just one shelf to another disk adds that folder alongside the existing
shelves. A different book later added at the old path receives a separate
entry. No NAS-wide content scan is used.

## Add a soundtrack or commentary

On mpv, open **Tracks → Add audio file**. **Replace soundtrack** selects the
external file. **Mix with movie** keeps the movie soundtrack and provides
separate movie/commentary volume controls. Adjust alignment in 100 ms steps.

The app keeps a private copy of the selected audio. Removing the attachment
removes that copy, preserving the original. The selection, gains and delay are
saved per profile and physical movie edition. Playback uses one native clock,
including after pauses and seeks. Mixing uses decoded audio. Removing it
restores the previous audio selection, delay and passthrough option. An existing
unrelated native audio graph is preserved.

## Browse a CUE album as individual tracks

Local folders and SMB shares recognize `.cue` sheets alongside supported audio
files. Album and track titles, performers and track order enter the source
index. Open an indexed track and select **Add to queue**. Tracks from local folders and SMB shares can share a queue, including tracks stored under identical filenames. Queue selection, shuffle, repeat and system transport buttons use the track entries. INDEX 01
provides sample-accurate CD-frame offsets; INDEX 00 pregaps remain with the
preceding track. Playing the album opens the original continuous files.

Individual tracks use bounded, zero-based native EDL timelines. Seeking or
repeating a track stays within that track. All tracks refer to the same
physical file fingerprint, so the download is stored once. CUE playback uses
mpv, including on TVs whose normal music engine cannot parse EDL. Invalid,
missing-file, traversal and reversed-timing sheets are ignored while their
ordinary media files remain browsable.

For albums with performer metadata, playing a track individually or playing the
continuous album records qualified listens per song. A song longer than 30
seconds qualifies after half its duration or four minutes of observed playback,
whichever comes first. Pauses and seeks do not earn listening time. Use the
export icon on a CUE album or track to save the current profile’s CUE listening
history in Audioscrobbler 1.1 format. The log can be imported into a compatible
scrobbler. Submission to a listening service is a separate user action.

## Read authored comic panels

In the comic reader settings, select **Guided panels**. ACBF manifests in comic
archives, and standalone ACBF with embedded images, supply the author’s panel
sequence. Tap the edges or use next/previous to move through it. Tap the centre
or press Enter to toggle the full page without losing the panel position.

The locator retains the physical page and panel through resume and rotation.
Right-to-left navigation preserves the authored sequence. Splash pages and
pages without authored frames remain full-page views. Invalid or out-of-image
frames fall back safely; there is no automatic panel guessing.

## Rewind a native RomM game

Hold **Left Trigger**, **Backspace**, or the on-screen rewind control. Release
to continue from the selected moment. Recent core states live only in a bounded
16 MiB session buffer, with at most 60 snapshots. Permanent save slots are not
rewritten while previewing the past. Loading a saved state clears rewind
history. Pause, controller disconnect and lifecycle changes release rewind.

Cores without state serialization, very large states, and serialization that
exceeds a frame budget disable capture for the session. The control reflects
whether rewind history is available. Snapshot frequency adapts to measured
capture cost. The practical history length depends on the core and device.

## Verification and packaging

The maintained tests cover destination collisions and writer/journal failures,
async buffer startup/stop, unequal episode bounds, profile/cut separation,
queue navigation, CUE frame offsets and shared fingerprints, folder content
verification, ACBF parsing, attachment restoration and rewind memory limits.

`python3 scripts/checks/verify_native_media_tools.py --libmpv /path/to/libmpv`
executes generated commentary pulses before and after seeking, episode/CUE
slices and one-connection buffered recording against the supplied native build.
`dart scripts/checks/verify_manual_capture_recovery.dart` generates a playable
transport stream, injects writer/destination/journal faults into the production
finalizer, checks every surviving byte and decodes its video and audio.
These checks inspect decoded output, not only command acceptance. Physical TV/controller
performance still needs device qualification.

The native muxer/filter build changes are in
[mpv-build 31c7da3](https://github.com/snapetech-org/mpv-build/commit/31c7da326fc9975311ff68851d691267ecb810c3).
The hosted native build is in progress; the previously pinned artifacts do not
qualify the new recording/commentary paths. Artifact promotion must retain
verified checksums and complete platform coverage.

## Upstream sources

The live-buffer interaction draws on [TiVo’s viewer guide](https://www.tivo.com/assets/pdfs/accessibility/TiVo_VG_Complete.pdf).
[Plex’s multi-episode naming documentation](https://support.plex.tv/articles/naming-and-organizing-your-tv-show-files/)
describes why multiple entries can share one file.
[Jellyfin’s external audio documentation](https://jellyfin.org/docs/general/server/media/movies/)
and [RiffTrax’s playback guide](https://www.rifftrax.com/howto) informed the two audio use cases.
[Kodi’s CUE-sheet documentation](https://kodi.wiki/view/Cue_sheets) and the
[ACBF specification](https://github.com/ACBF-Advanced-Comic-Book-Format/ACBF)
provide format references. These are documentation/use-case credits; Pleazyng
independently implemented and verified the downstream integration. See the
[attribution ledger](../../UPSTREAM_ATTRIBUTION.md).
