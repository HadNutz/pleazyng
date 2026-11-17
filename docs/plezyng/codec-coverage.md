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
  Android JSON. A first launch waits briefly for the initial inventory after
  player setup. Unmeasured mpv negotiates H.264 and any positively reported
  HEVC or AV1 hardware support. A source negotiation uses its own playback
  engine, including when the primary player takes a different route.
- Add measured video decoders to Jellyfin/Emby direct-play profiles, including
  VVC, professional and historical codec identities. Enumerated containers
  expand the original static list. MPEG, AVI, ASF, RealMedia, MXF and others
  are negotiated only when their demuxer is present.
- Tizen uses the native H.264 profile and checks the source frame rate and bit
  depth where available. webOS advertises LG's documented container/codec
  pairs, adding AV1 and VP9 on modern UHD models that report the SDK version
  and UHD capability. ExoPlayer uses Android's decoder list, and checks known
  profile, dimensions, and frame rate together on the selected decoder type.
  These checks describe declared capabilities; real-time and HDR output still
  require device testing.
- Add raw `.apv` file discovery. Server container matching uses independently
  measured demuxers for aliases such as `.qt`, `.mj2`, `.m2t`, `.dvr-ms`, and
  `.ogm`. Elementary streams keep their own type rather than pretending to be
  a muxed container.
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
  architectures. The pinned AVS2 dependency is 8-bit only. The application
  lock consumes verified published native packages for all four platform groups.

- For the selected AC-4 or MPEG-H audio track, a measured decoder absence
  requests server audio conversion with video stream copy available. This
  requires a server decoder and leaves unmeasured TV capabilities to the
  platform playback stack.

## Expanded qualification

The companion producer adds a 48-fixture Linux release corpus covering software
decode and seek, codec bit depths and chroma formats, HLS/DASH VOD, DTS and
TrueHD PCM, and six text or bitmap subtitle formats. Four passthrough cases
check software IEC 61937 output. Eight hash-pinned reference vectors cover
APV, VVC, EVC, AVS2, AVS3 and both JPEG XL forms.

The native manifest at `7aff0ff256b7` pins Linux and Android packages with
JPEG XL and DASH enabled. Its Linux x86_64 and ARM64 builds passed 52 playback
checks including DASH, plus the reference JPEG XL cases, DVD title playback
and recovery from an injected HTTP 503 during HLS playback. The hosted
Android build passed all four ABIs and packaged the AAR.
See the [producer coverage report](https://github.com/snapetech-org/mpv-build/blob/main/docs/codec-coverage.md#reference-vectors-and-dash).

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

The application lock now consumes the producer's verified published artifacts
for all four platform groups. Apple passed all six target builds and iOS/tvOS
Objective-C-only SwiftPM consumer links; Android passed all four ABI builds and
AAR/JVM checks; both Linux architectures passed the 28-case decode/seek corpus
and enhanced-resolution LCEVC checks. Windows x64 and ARM64 passed production
build, PCM ABI, packaging and publication gates. The SDK implementation and
notices are bundled; end users do not install a decoder SDK. Physical-device,
real-time, HDR and codec-profile qualification remains separate.
Native webOS/Tizen/ExoPlayer backends do not gain this SDK from mpv packaging.
AV2 direct play requires a loaded mpv engine reporting the AV2 decoder. The
native producer integrates VideoLAN dav2d with FFmpeg for AV02 IVF and raw
OBU streams. The Linux reference check covers 130 frames and a one-second
IVF seek. File discovery recognizes the raw `.av2` and `.obu` extensions.
Clients running older native packages still request an available server
conversion for AV2. Native TV and Android platform engines negotiate separately.
[Decoder source](https://code.videolan.org/videolan/dav2d).
[FFmpeg decoder and demuxer proposal](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/23018).

Fraunhofer's MPEG-H decoder SDK is public; a private SDK login is not the
missing dependency. The pinned FFmpeg integration classifies `libmpeghdec` as
nonfree, so it is not enabled in the normal redistributable packages. A
recognized MPEG-H name therefore does not establish local decoding. See the
[public SDK and its terms](https://github.com/Fraunhofer-IIS/mpeghdec/tree/4448b69738da2fa5f2f2f2b0ce29eea32509e046)
and the producer's [SDK bundling decisions](https://github.com/snapetech-org/mpv-build/blob/main/docs/codec-coverage.md#sdk-bundling-decisions).
Unavailable decoder routes must keep an honest unsupported or available
server-conversion result; recognition never substitutes for an implementation.

The native producer's local validation now includes exact upstream YUV hashes
for AVS2 8-bit and AVS3 8/10-bit, Android final shared FFmpeg links for all four
ABIs, and a headless VA-API control test for LCEVC. The latter reproduced a
silent base-layer-only hardware result and verified targeted software replay
at enhanced resolution while ordinary H.264 retained hardware decoding.
The pin update carries these verified producer artifacts into normal app
builds. The pre-decode LCEVC detector handles AVC/HEVC registered-user-data SEI
and packet-side enhancement metadata; it is not a claim of every LCEVC base
codec/profile combination. All validation here ran headlessly.

`set_native_revision.sh` also checks `LCEVCdec.sources.json` against the SDK
source commit/version and the exact app notice payload. A future SDK update or
altered notice fails before any platform pin is written, preventing a static
framework's resource-copy behavior from dropping its licensing information.
