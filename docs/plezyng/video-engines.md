# Video engines

Choose an engine under **Settings → Playback → Video player**. The selection applies to new video sessions. Dedicated music playback keeps its own player.

| Target | Engines | Default |
| --- | --- | --- |
| Android phones, tablets and TV | mpv, Media3 ExoPlayer, Android MediaPlayer | mpv for new installs; an existing explicit selection is migrated |
| iOS, iPadOS, tvOS, macOS | mpv, AVPlayer | mpv |
| Windows x64 and Arm64 | mpv, Media Foundation | mpv |
| Linux x64 and Arm64 | mpv, GStreamer playbin | mpv |
| LG webOS | LG native media player, mpv | LG native media player |
| Samsung Tizen | Samsung native media player, mpv | Samsung native media player |

ExoPlayer uses Android APIs. The system choices use each OS's playback stack. An installed decoder, a decoder selected for a stream, and the signal actually presented by a display are separate observations. Server negotiation follows the engine selected for that source. Original quality on TV preserves source resolution. Lower quality presets continue to request their configured dimensions. For the desktop system players the app queries GStreamer's installed decoders and demuxers, Media Foundation's decoder transforms, or AVFoundation's playable MP4 codecs. A software decoder can accept an original file. A reported hardware decoder also enables HEVC or AV1 as a preferred server transcode output.

Hardware decoding is enabled by default for new video sessions, including previews and secondary players. mpv tries the platform decoder for the source codec and falls back when it cannot decode the stream. ExoPlayer tries compatible hardware MediaCodec components before software ones. GStreamer prefers hardware video decoders for each session and can retry software when a driver fails during preparation. These engines respect a saved hardware-decoding preference. Features that require CPU-decoded frames can still select software.

AVPlayer, Android MediaPlayer, Media Foundation and the native Samsung and LG players use the operating system’s decoder selection. Original quality preserves the source resolution independently of decoder selection.

## Desktop presentation

Media Foundation opens a windowless DirectComposition swapchain beneath the Windows controls. Windows negotiates its video format. If the swapchain cannot open, the player retries through the BGRA8 texture. The performance overlay shows the presentation route and, when DXGI reports it, the current monitor signal and bits per channel.

GStreamer uses a native video subsurface when the installed Wayland sink supports HDR10 metadata (1.28 or later) and the compositor advertises HDR colour management. The sink negotiates a format with the compositor, including DMA-BUF where available. The overlay shows the negotiated format and any compositor colour preference. The compatibility path reads ten-bit RGB and tone maps PQ or HLG to the eight-bit SDR texture. Both routes retain the decoded frame dimensions.

## TV hardware paths

On webOS, mpv can demux H.264, HEVC, VP9 and AV1 for LG DirectMedia. mpv schedules compressed access units in decode order, passes their original presentation timestamps to the hardware and renders video on an exported LG window. When H.264 or HEVC has reordered pictures and no decode timestamps, the LG path buffers up to 17 compressed packets to recover the presentation cadence, including on variable-frame-rate video. H.264 and HEVC from MP4 are reframed as Annex B. For HDR VP9, the adapter sends container colour and mastering metadata to DirectMedia. Flutter draws the controls and sidecar text over the plane. For embedded subtitles, mpv renders a separate transparent texture while DirectMedia continues decoding the original video. The NDL path seeks to keyframes so the decoder receives its reference pictures. The LG URI player remains an independent option for native track handling and HDR formats.

When the LG plane is unavailable or refuses a source during preparation, mpv reopens the stream on its texture output. On both TV systems this output tries FFmpeg's V4L2 memory-to-memory decoder when firmware exposes a compatible device. It can fall back to CPU decoding. The texture carries eight-bit RGBA and can hold a 3840×2160 source. The physical resolution of a TV's graphics compositor and real-time performance vary. The native video planes bypass that texture allocation. Samsung's native player supports original-quality UHD candidates and the server conversion target remains available for incompatible media.

The TV build starts from [ales-drnz/libmpv-scripts](https://github.com/ales-drnz/libmpv-scripts/tree/51a0ac0897bb7fefd95ba65747b4712e75f6353b). Pleazyng enables video codecs and renderers, adds the LG decoder/output pair, and packages the library, dependency notices and a digest in each TV application. The LG packet path follows the SDK and the [webOS community's DirectMedia samples](https://github.com/webosbrew/samples/tree/main/media/ndl/directmedia). Samsung publishes [codec and UHD limits by model year](https://developer.samsung.com/smarttv/develop/specifications/media-specifications.html).

## Qualification

The ARM DirectMedia fixture captures the packets that the webOS build sends to the decoder. A 3840×2160 ten-bit HEVC source with B-frames retained its PQ transfer characteristic and produced identical decoded pixels after capture. The fixture substitutes the device API and cannot measure the panel. The libmpv texture fixture checks decoded RGBA pixels under ABI emulation. Subtitle fixtures check that an embedded cue appears and clears on the LG overlay and the Samsung texture. On retail hardware, verify the actual decoder, sustained playback, A/V sync, pause and seek, subtitle presentation, panel mode and HDR metadata with the same source. Hardware paths are enabled on compatible devices independently of those measurements.
