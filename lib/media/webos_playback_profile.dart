import 'media_display_criteria.dart';

/// LG's webOS TV 24–26 format tables describe AV1 and VP9 on UHD sets.
/// Use the installed SDK version and UHD device flag before offering them.
Map<String, Set<String>> webosVideoContainers({required bool modernUhd}) => {
  'mp4,m4v,mov': {'h264', 'hevc', 'mpeg4', if (modernUhd) 'av1'},
  'mkv': {
    'h264',
    'hevc',
    'mpeg2video',
    'mpeg4',
    'vp8',
    if (modernUhd) ...{'av1', 'vp9'},
  },
  'ts,mpegts,mts,trp': {'h264', 'hevc', 'mpeg2video'},
  'avi': {'h264', 'mpeg4', 'mjpeg'},
  'mpg,mpeg,vob': {'mpeg1video', 'mpeg2video'},
  '3gp,3g2': {'h264', 'mpeg4'},
};

bool webosVideoFormatUnavailable(String codec, MediaDisplayCriteria source, {required bool? uhd}) {
  final bitDepth = source.bitDepth;
  if ((codec == 'h264' && (bitDepth ?? 0) > 8) || (codec == 'hevc' && (bitDepth ?? 0) > 10)) return true;
  return uhd == false && ((source.width ?? 0) > 1920 || (source.height ?? 0) > 1080 || (source.fps ?? 0) > 60);
}

/// A fallback target used only after the native audio path rejects a format.
/// Initial playback keeps original audio and the TV/receiver's passthrough.
const webosTranscodeAudioCodecs = 'eac3,ac3,aac,mp3';

/// Initialization, window, network and output-device failures do not establish
/// an unsupported codec. Only explicit native audio-format rejection does.
bool webosMediaErrorRejectsAudio(Object? error) {
  if (error == null) return false;
  final message = error.toString().toLowerCase().replaceAll(RegExp(r'[_-]'), ' ');
  // NDL prefixes controller errors with its numeric MediaPipelineStatus.
  // 200 is SMP_AUDIO_CODEC_NOT_SUPPORTED even when the firmware localizes the text.
  if (RegExp(r'^200(?:\s|$)').hasMatch(message)) return true;
  return RegExp(
    r'(?:unsupported|not supported).{0,48}(?:audio codec|audio format|dts|truehd)'
    r'|(?:audio codec|audio format|dts|truehd).{0,48}(?:unsupported|not supported)',
  ).hasMatch(message);
}

bool webosMediaErrorRejectsVideo(Object? error) {
  if (error == null) return false;
  final message = error.toString().toLowerCase().replaceAll(RegExp(r'[_-]'), ' ');
  // 201 is SMP_VIDEO_CODEC_NOT_SUPPORTED.
  if (RegExp(r'^201(?:\s|$)').hasMatch(message)) return true;
  return RegExp(
    r'(?:unsupported|not supported).{0,48}(?:video codec|video format|dolby vision)'
    r'|(?:video codec|video format|dolby vision).{0,48}(?:unsupported|not supported)',
  ).hasMatch(message);
}
