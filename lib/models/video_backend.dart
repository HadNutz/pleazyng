import 'dart:io';

import '../utils/platform_detector.dart';

enum VideoBackend { mpv, exoplayer, system }

enum VideoHost {
  android('mediaplayer', 'Android MediaPlayer'),
  apple('avplayer', 'AVPlayer'),
  windows('mediafoundation', 'Media Foundation'),
  linux('gstreamer', 'GStreamer'),
  webos('webos', 'LG webOS Media Player'),
  tizen('tizen', 'Samsung Tizen Player');

  const VideoHost(this.nativeId, this.nativeLabel);
  final String nativeId;
  final String nativeLabel;

  static VideoHost get current {
    if (PlatformDetector.isWebOSBuild()) return webos;
    if (PlatformDetector.isTizenBuild()) return tizen;
    if (Platform.isAndroid) return android;
    if (Platform.isIOS || Platform.isMacOS) return apple;
    if (Platform.isWindows) return windows;
    if (Platform.isLinux) return linux;
    throw UnsupportedError('Unsupported video platform');
  }

  List<VideoBackend> get choices => switch (this) {
    webos || tizen => const [VideoBackend.system, VideoBackend.mpv],
    android => VideoBackend.values,
    _ => const [VideoBackend.mpv, VideoBackend.system],
  };

  String resolve(VideoBackend preference) {
    final choice = choices.contains(preference) ? preference : choices.first;
    if ((this == webos || this == tizen) && choice == VideoBackend.mpv) return 'tvmpv';
    return choice == VideoBackend.system ? nativeId : choice.name;
  }
}
