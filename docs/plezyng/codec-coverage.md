# Codec and playback coverage

## Contract

An extension identifies a candidate file. A decoder inventory identifies a
compiled implementation. Neither establishes successful playback, real-time
performance, hardware acceleration, a supported codec profile, correct HDR
output, spatial-audio passthrough, or device qualification.

Original-source decoding and server output encoding use separate lists. Do not
add a decoder to AV1/HEVC/H.264 output preferences merely because it can read a
source. Native webOS, Tizen and ExoPlayer never inherit mpv's inventory.

## Implemented

- Observe mpv `decoder-list` and `demuxer-lavf-list`, accepting native nodes or
  Android JSON. Invalid/missing observations leave capabilities unknown.
- Add measured video decoders to Jellyfin/Emby direct-play profiles, including
  VVC, professional and historical codec identities. Enumerated containers
  expand the original static list. MPEG, AVI, ASF, RealMedia, MXF and others
  are negotiated only when their demuxer is present.
- Keep the existing AV1/HEVC/H.264 preference and user-refusal policy for server
  output. A missing source decoder requests conversion, and conversion failure
  cannot silently reopen that same unsupported source.
- At Original quality, honor an explicit Jellyfin/Emby direct-play refusal and
  its returned conversion URL. Preserve an explicit retry position.
- Record codec evidence in copied/saved/uploaded logs without media URLs,
  credentials or file paths. `executionQualified` remains false.
- Recognize the expanded modern, professional and historical video/audio
  extensions in all shared file-source browsers.
- Generate the complete video/audio/subtitle naming catalogue from the pinned
  FFmpeg descriptors (282 video, 225 audio, 27 subtitle identities). Long-tail
  video names can enter direct-play negotiation only after runtime enumeration;
  a generated name alone never advertises an installed decoder.
- Companion `snapetech-org/mpv-build` preserves the broad built-in FFmpeg
  decoder, demuxer, parser and bitstream-filter sets. Linux packages generate
  a binary-hashed inventory and require a software AV1 implementation.
  Its Linux, Android, Apple and Windows source graphs include EVC, AVS2,
  AVS3 and static LCEVCdec. The Linux release gate requires H.264, HEVC,
  software AV1, VP9, MPEG-2, VC-1, MPEG-4, VVC, EVC, AVS2 and AVS3, plus
  generated decode/seek corpus and LCEVC reconstruction checks on both native
  architectures. The pinned AVS2 dependency is 8-bit only. Native packages
  must be rebuilt and consumed before these source integrations exist in an
  installed application.

## Coverage order and remaining qualification

| Priority | Families | Required evidence |
| --- | --- | --- |
| 1 | AVC, HEVC, AV1, VP9 | Profiles, 8/10/12-bit, 4:2:0/4:2:2/4:4:4; hardware/software routes; HDR and seek |
| 2 | VVC, AV2, EVC, LCEVC, AVS2/3 | Actual linked decoder and conformance samples; recognition alone is insufficient |
| 3 | VP8, MPEG-1/2/4, VC-1/WMV | Interlace, timestamps, AVI indexes and software fallback |
| 4 | ProRes/RAW, DNx, CineForm, DV, MJPEG, JPEG 2000, FFV1, HuffYUV, UT, raw, APV | Pixel format/color fidelity, large frames, alpha and performance |
| 5 | Remaining FFmpeg historical codecs | Decoder/demuxer inventory plus fixtures per family |
| 6 | MVC/MV-HEVC, SBS/TB, 360, alpha | View selection/composition and physical output verification |

Audio decoding, PCM output, passthrough, object metadata, containers, subtitle
rendering, streams and disc navigation each need independent tests. A codec
family being listed does not mean every member or output mode is implemented.
DRM requires the relevant authorized playback stack. Undecodable encrypted,
corrupt or proprietary sources must report the actual limitation.

Cross-platform native rebuilds, actual bundled inventory reports, representative
decode/seek fixtures and physical-device HDR/audio tests are release evidence.
Do not mark this matrix universally qualified from Dart tests or a build alone.

## Bundled SDK delivery

The native producer now builds pinned LCEVCdec 4.3.1 statically for Linux,
Android, Windows and Apple. No user-installed decoder SDK is required. Its
FFmpeg integration reconstructs enhancement data through the generic video
decode path; an `lcevc` entry in a codec-name catalogue is not proof of that
reconstruction. Base-layer-only decoding must not count as LCEVC qualification.

The SDK's original `COPYING` and `LICENSE.md` are retained in native packages,
Android AAR assets and the application's Licenses screen. BSD-3-Clause-Clear
and the additional licensing information remain the SDK's own terms; they
explicitly exclude a patent license. See the [pinned SDK source and terms](https://github.com/v-novaltd/LCEVCdec/tree/e295d8438ba554bc541fb269baa9cbd567b626a8).

The application remains on its last verified native pin until the producer's
new all-platform artifacts pass publication and pin verification. These source
changes do not themselves establish shipped or device-qualified LCEVC support.
Native webOS/Tizen/ExoPlayer backends do not gain this SDK from mpv packaging.
AV2 v1.0.0 is final. VideoLAN's May 2026 status describes dav2d as a
functional early decoder with 8/10-bit decoding, while conformance,
optimization and platform support remain active work. The pinned FFmpeg has
no AV2 codec ID, decoder wrapper or demuxer integration, so filename or
server-metadata recognition cannot enable local AV2 playback. Current mpv
inventories therefore exclude AV2. When a valid inventory shows no source
decoder, Jellyfin/Emby playback requests a compatible server conversion; if
none is offered, the client reports the unsupported source instead of retrying
the same file. Sources: [AV2 v1.0 specification](https://av2.aomedia.org/),
[VideoLAN dav2d status](https://jbkempf.com/blog/2026/dav2d/).

Unavailable proprietary SDKs must likewise keep an honest unsupported or
server-conversion route; recognition never substitutes for an implementation.

The native producer's local validation now includes exact upstream YUV hashes
for AVS2 8-bit and AVS3 8/10-bit, Android final shared FFmpeg links for all four
ABIs, and a headless VA-API control test for LCEVC. The latter reproduced a
silent base-layer-only hardware result and verified targeted software replay
at enhanced resolution while ordinary H.264 retained hardware decoding.
These are producer validation results; app delivery still requires the verified
native pin update above. No TV input or visible playback was changed.

`set_native_revision.sh` also checks `LCEVCdec.sources.json` against the SDK
source commit/version and the exact app notice payload. A future SDK update or
altered notice fails before any platform pin is written, preventing a static
framework's resource-copy behavior from dropping its licensing information.
