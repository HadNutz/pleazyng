# Vega OS motion preview

This experimental Fire TV client opens an HTTPS media URL. A direct-play link from a media server works when the server permits byte-range requests and cross-origin access. The preview has its own package ID. Plex and Jellyfin account browsing, DRM, and NPU inference are outside this preview.

The video element owns audio and playback time. For clear on-demand video, a second decoder supplies frame pairs to a WebGL 2 temporal mixer. When WebGL fails the player tries a CPU pixel mixer. Decoder availability, color transfer and read access are checked for each stream. An unavailable or stalled mixer returns presentation to the original video. Performance and Quality change the blend weights during playback.

With the Vega 2 SDK active, Node 20 or later and npm available, run the following from the repository root.

```sh
vega/build.sh /path/to/new/output-directory
```

The build generates the WebView shell using Amazon's SDK and packages local assets for armv7, aarch64 and x86_64. For an Apple Silicon virtual device, choose the package matching its architecture. On Linux x86_64 the official virtual device rejects the required WebView module at install. Our Android WebView engine test played a 320×180 H.264 clip through both mixers and restored the original video while playback advanced. Physical Vega rendering and throughput remain unverified. [Amazon WebView device requirements](https://developer.amazon.com/docs/vega/2.0/develop-your-app-with-webview)
