# Native subtitle sidecar calibration

Main-library MPV text sidecars can be aligned by selecting subtitle cues and
capturing the playback position at which each cue should appear. Calibration
uses the existing subtitle rate and delay controls. Preview is temporary;
Save writes through the existing scoped player preferences and keeps one-step
Undo behavior. No server track or source file is edited.

## Scope and clock

The calibration action is offered only when the selected native subtitle maps
to a discovered source sidecar that can be read as a bounded local file or
HTTP(S) resource. SRT, WebVTT, ASS, and SSA can be inspected for cue selection.
The reader accepts at most 5 MiB, has a 20-second operation limit, rejects
HTTP redirects, and does not persist or log the sidecar URI. Piecewise export
currently supports SRT and WebVTT only.

Cue anchors retain the parser's stable cue ID and the cue's source-file clock
time. Captured playback positions are converted from the player's item
timeline to the opened media-part clock by subtracting the part offset. The
saved identity includes the profile, server item, media index, part ID and
offset, audio stream, subtitle stream, primary/secondary lane, and exact
sidecar SHA-256. Raw IDs and URLs are not written to history; persisted scope
identifiers are SHA-256 values.

Native affine correction requires two or more increasing anchors, a same-clock
pair at least 60 seconds apart, a rate from 0.80× through 1.25×, a delay within
±60 seconds, and maximum absolute residual no greater than 750 ms. Up to 12
anchors can be used. Preview and Save are offered only for the primary lane
when the player already supports native subtitle drift correction. Other
supported lanes can use the separate export path.

## History and export

History is device-local and never applies a correction when opened. A record
stores cue IDs, both clock values, explicit cut markers, the fit diagnostics,
and the prior user rate and delay. The record is visible only for the same
profile/item/part/audio/lane identity and exact sidecar bytes. Retention is
capped at 8 records and 512 KiB per exact scope, 64 KiB per record, and 512
record files / 64 MiB globally. Reads scan at most 1,024 directory entries.
History writes are atomic; invalid or incomplete records are ignored.

The export ZIP contains the exact source bytes, a separate corrected copy,
hashes, the selected clock mapping and anchors, prior player settings, and
clipping counts. The total archive is capped at 12 MiB. Export never attaches a
track or changes the player's settings. Before-zero cues that would be removed
require explicit confirmation. Piecewise SRT/WebVTT export uses one shared
rate and an explicit offset per marked segment. At least one segment must have
two anchors 60 seconds apart; anchors within each segment must agree within
750 ms. Mark the first cue after a known cut. A cue that spans a marked cut is
refused rather than stretched across the discontinuity. ASS/SSA piecewise
export remains unsupported.

## Identity limits and qualification

The content digest identifies the exact bytes read for the calibration and
export operations. A server can replace the sidecar after that read, and a
player may already have buffered a different representation for the same
catalog track. The app re-reads the selected URI before native preview/save and
before export, but cannot atomically bind those bytes to the server's player
buffer. The ZIP manifest states this limit. A replacement with different bytes
gets a different history key even when the catalog identity and URL stay the
same.

This implementation makes no device, subtitle color, renderer, or visual
qualification claim. ASS/SSA display behavior and platform text-renderer
differences remain dependent on the active player. The source-level tests cover
the read limit, exact-byte history scoping, clock fits, cut boundaries, source
preservation, and export manifests. Retention limits are enforced by the
history service; device playback qualification remains separate.
