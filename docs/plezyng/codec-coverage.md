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
  Its Linux, Android, Apple and Windows source graphs include AV2, EVC,
  AVS2, AVS3 and static LCEVCdec. The Linux release gate requires H.264, HEVC,
  software AV1, VP9, MPEG-2, VC-1, MPEG-4, VVC, EVC, AVS2 and AVS3, plus
  generated decode/seek corpus and LCEVC reconstruction checks on both native
  architectures. The AVS2 integration selects the 8-bit or Main 10 decoder
  from the stream headers.

- For the selected AC-4 or MPEG-H audio track, a measured decoder absence
  requests server audio conversion with video stream copy available. This
  requires a server decoder and leaves unmeasured TV capabilities to the
  platform playback stack.

## Expanded qualification

The companion producer runs a Linux release corpus covering software
decode and seek, codec bit depths and chroma formats, HLS/DASH VOD, DTS and
TrueHD PCM, and six text or bitmap subtitle formats. Four passthrough cases
check software IEC 61937 output. Hash-pinned reference vectors cover
AV2, APV, VVC, EVC, AVS2, AVS3 and both JPEG XL forms.

Native manifest `ab5e90ab2cb7` published the following results from the
[release build](https://github.com/snapetech-org/mpv-build/actions/runs/44209533457).

| Platform | Evidence |
| --- | --- |
| Linux x86_64 and ARM64 | Each shipped library reported 489 decoder identities and passed 68 generated playback checks, 12 reference cases, audio CD, DVD, Blu-ray, interrupted HLS recovery and LCEVC reconstruction. Both decoded and sought through 8-bit and 10-bit AV2. |
| Apple | All six targets built. The published Libavcodec and Libavformat archives contain the AV2 decoder, its dav2d implementation, the IVF reader and the raw AV2 OBU reader in all 11 architecture slices. |
| Windows x64 and ARM64 | Both DLLs built and passed packaging. Running the published DLLs against the playback corpus on Windows remains open. |
| Android armeabi-v7a, arm64-v8a, x86 and x86_64 | The AAR's FFmpeg libraries decoded the two AV2 IVF vectors and the raw 8-bit OBU vector on Android API 25. The decoded frame counts and full-sequence pixel digests matched the independent AVM reference on each ABI. The full player in this AAR fails to load due to unresolved Brotli imports. |

Android AAR `2c3eac114e23` and the preceding x86_64 native package
`1adb03337a50` omit part of Brotli from libmpv's FreeType dependency.
The Android loader rejects the library before opening media. The
[producer fix](https://github.com/snapetech-org/mpv-build/commit/4f394a24d88dc40f269f9c3d3ddffd43c56a1b15)
links Brotli's common code statically into the player and checks imports
in each release tarball and the stripped AAR against Android API 25.
A locally rebuilt x86_64 libmpv opened the 480×270 AV2 IVF, sought to
one second and resumed to EOF under Android 7.1 with the packaged FFmpeg
libraries. The app needs a new published Android package for this fix.

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

The initial LCEVC release covered all four platform groups. Apple passed all six target builds and iOS/tvOS
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
Jellyfin and Emby advertise AV2 only with its matching demuxers. For MP4
and Matroska, the current integration requests conversion. The draft MP4
sample-entry names `av2e` and `av2E` identify the codec for that decision.
[AOMedia AV2 ISOBMFF working draft](https://aomediacodec.github.io/av2-isobmff/main/index.html).
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

The native producer's local validation includes exact upstream YUV hashes
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


Android ExoPlayer includes Media3’s HLS, DASH, SmoothStreaming and RTSP
source factories. Direct tuner transport streams and radio streams can use
the progressive extractors. Opaque live HTTP endpoints still try HLS first.
When the root response lacks the playlist header, its content type or final
URL chooses DASH or SmoothStreaming, with progressive sniffing for other
payloads. The retry is limited to once per open. The Android unit tests
instantiate the actual factories and exercise the HLS parser’s error path.


The Linux x86_64 AVS2 Main 10 package from native revision `85d395c`
passed ten reference cases after publication. These included the 4K 10-bit
AVS2 broadcast with a seek, the EVC MP4 seek through 23.96 seconds and both
JPEG XL references. A separate two-track audio CD seek produced stereo PCM.
The package SHA-256 is `046e2939689c4d9603951307e233451e16d87890cb004cfcace4864ee8690e46`.
[Native build and publication](https://github.com/snapetech-org/mpv-build/actions/runs/44198900192).

The AV2 FFmpeg decoder and IVF/raw OBU demuxers at native revision
`b2ed619` also cross-compiled and linked for armeabi-v7a, arm64-v8a, x86
and x86_64 against the pinned Android NDK at API 25. The same decoder and both demuxers linked as Windows x64 and ARM64 FFmpeg
DLLs using LLVM-MinGW 22.1.8. Android-targeted Bionic executables then decoded both IVF references and the
raw 8-bit OBU reference on each ABI. All 12 runs matched the independent AVM
pixel hashes. x86_64 ran directly on Linux and the other three ran under
QEMU user-mode emulation. Physical Android and Windows playback remains
unverified.

Apple published all six XCFramework variants from revision `85d395c`.
The Libavcodec archive (SHA-256 `9ee6a5a4f1e1f1fdbbc36d7b6ebc679f475526035c3a6afb9e0f5051d027e61b`)
contains the JPEG XL and AVS2 decoder wrappers and implementations in all 11
architecture slices. The hosted iOS and tvOS SwiftPM consumer links passed.
Apple hardware playback is pending.

All 68 generated playback checks in [the expanded release gate](https://github.com/snapetech-org/mpv-build/commit/e79431f088fedc32455281bb8e5e0abbc6bc196c)
passed through the same published x86_64 Linux library. This includes DNxHR LB,
10-bit CineForm, PAL DV, v210, Ut Video, DOSBox recordings, TTA and ADPCM.
Raw AVC, HEVC, VVC, AVS2/3, EVC, APV, MPEG video and YUV4MPEG server
profiles now use measured demuxers and matching codecs. JPEG XL still and
animation have separate demuxer checks. Original raw Motion JPEG captures
select the MJPEG reader in mpv, including Android's mpv fallback. The default
still-image reader displayed one frame of a 50-frame capture. The file-local
choice displayed all 50. Raw AVC, HEVC, MPEG-2, AV1 OBU and YUV4MPEG also
displayed all 50 frames through the published Linux package. Offline cleanup uses the same file
extensions as the source browser and retains its item identity and path checks.

For local music, Jellyfin and Emby receive the dedicated audio engine’s
container and decoder pairs, independently of the video engine preference.
These include PCM and ADPCM variants, WavPack, True Audio, Monkey’s Audio,
TAK, Shorten, Musepack, DSD/DST, ATRAC and RealAudio. The Linux x86_64
package at app pin `7aff0ff` played 14 FFmpeg reference clips to EOF,
including both Musepack versions, three ATRAC generations, DSDIFF/DST and
four older lossless formats (TAK, Shorten, RKA and OSQ). All 14 produced
the reference duration at 48 kHz. At 44.1 kHz, 12 produced byte-identical
stereo PCM to the host FFmpeg decoder. The ATRAC3 and DSDIFF/DST
conversions differed at that output rate. Shorten, RKA, OSQ and MLP
also matched FFmpeg’s published PCM digests at their native sample rate.
[FFmpeg reference samples](https://fate-suite.ffmpeg.org/).

AC-4 software qualification covered two implementations. The FFmpeg proposal
decoded the stereo reference exactly and the short 5.1 stream. Its immersive
transport stream produced no PCM and its 5.1.4 MP4 failed during playback.
The alternate decoder emitted PCM for that MP4 but lost audio on the immersive
transport stream and aborted on the immersive raw sample. These builds keep
the available platform or server route for AC-4.
[FFmpeg decoder proposal](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/25444).
