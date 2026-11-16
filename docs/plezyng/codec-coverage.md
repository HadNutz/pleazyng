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
- Companion `snapetech-org/mpv-build` preserves the broad built-in FFmpeg
  decoder, demuxer, parser and bitstream-filter sets. Linux packages generate
  a binary-hashed inventory and require a software AV1 implementation.

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
