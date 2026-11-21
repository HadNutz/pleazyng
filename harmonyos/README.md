# Pleazyng for HarmonyOS NEXT

Open this directory as a Stage project in DevEco Studio. Select the default product, register the test device and enable automatic debug signing for the entry module. Run EntryAbility on a phone or tablet with HarmonyOS 6.0.1 (API 21) or newer.

The native launcher plays a selected local file, an HTTP(S) media URL, or a direct-play file from Plex, Jellyfin or Emby. Choose **Libraries**, enter the server address and use a Plex token or Jellyfin/Emby credentials. The browser keeps credentials in memory and sends the playback headers to AVPlayer. The current server must expose a directly playable media part. This client does not yet provide the Flutter catalog's downloads, transcoding negotiation, DRM or Watch Together.

The player keeps its XComponent and AVPlayer when the window resizes. On a separating crease it places the picture and transport on different panes. On a continuous display it keeps the controls below the video. Picture in picture uses the system video template when available. Network playback requests the HDR variant when the active display advertises a compatible format. Actual HDR output also depends on the source, decoder and panel.

## Build and install

With the DevEco command-line tools, Node, Java and the HarmonyOS SDK configured:

```sh
ohpm install
hvigorw --no-daemon assembleHap -p product=default -p buildMode=debug
```

The unsigned artifact is `entry/build/default/outputs/default/entry-default-unsigned.hap`. DevEco Studio can build a device-signed HAP using the developer's local signing configuration. To install that signed output and launch it:

```sh
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b org.snapetech.pleazyng
```

Test a local SDR clip, an authenticated library item and an HDR network source on both panels. Fold during playback and pause, drag the window across a crease, enter PiP, toggle playback from the system window, and return. Record the SDK, device, source format, physical output and playback position in the qualification matrix.
