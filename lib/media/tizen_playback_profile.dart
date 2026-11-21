import 'codec_catalog.dart';
import 'media_source_info.dart';
import 'media_version.dart';

/// Candidate original streams for Samsung's native media plane. Decoder
/// limits vary by model. A rejected native open can retry through mpv.
const tizenVideoContainers = <String, Set<String>>{
  'mp4,m4v,mov,mkv': {'h264', 'hevc', 'av1'},
  'ts,mpegts,m2ts': {'h264', 'hevc', 'mpeg2video'},
  'webm': {'vp8', 'vp9', 'av1'},
};
const tizenSourceAudio = {'aac', 'mp3', 'ac3', 'eac3', 'flac', 'opus', 'vorbis'};

bool tizenCanDirectPlayVideo(MediaVersion? version, MediaSourceInfo? source) {
  if (version == null || source == null) return false;
  final container = version.container?.toLowerCase();
  final codec = CodecCatalog.normalize(version.videoCodec ?? '');
  if (!tizenVideoContainers.entries.any((e) => e.key.split(',').contains(container) && e.value.contains(codec))) {
    return false;
  }
  final depth = source.displayCriteria?.bitDepth;
  if (depth != null && depth > (codec == 'h264' ? 8 : 10)) return false;
  return true;
}

Map<String, Object?> tizenPlaybackProfile({
  required bool audio,
  required bool burnSubtitles,
  Set<String> refusedVideo = const {},
  List<Map<String, Object?>> videoConditions = const [],
}) => {
  'Name': 'Pleazyng Samsung TV',
  'TranscodingProfiles': [
    {
      'Type': 'Video',
      'Container': 'ts',
      'Protocol': 'hls',
      'VideoCodec': 'h264',
      'AudioCodec': 'aac,mp3',
      'MaxAudioChannels': '2',
    },
    if (audio) {'Type': 'Audio', 'Container': 'mp3', 'Protocol': 'http', 'AudioCodec': 'mp3', 'MaxAudioChannels': '2'},
  ],
  'DirectPlayProfiles': [
    for (final entry in tizenVideoContainers.entries)
      if (entry.value.difference(refusedVideo).isNotEmpty)
        {
          'Type': 'Video',
          'Container': entry.key,
          'VideoCodec': entry.value.difference(refusedVideo).join(','),
          'AudioCodec': tizenSourceAudio.join(','),
        },
    if (audio) {'Type': 'Audio', 'Container': 'mp3,aac,m4a,m4b', 'AudioCodec': 'mp3,aac'},
  ],
  'CodecProfiles': [
    ...videoConditions,
    {
      'Type': 'Video',
      'Codec': 'h264',
      'Conditions': [
        {'Condition': 'LessThanEqual', 'Property': 'VideoBitDepth', 'Value': '8', 'IsRequired': false},
        {'Condition': 'LessThanEqual', 'Property': 'VideoFramerate', 'Value': '60', 'IsRequired': false},
      ],
    },
  ],
  'SubtitleProfiles': [
    if (!burnSubtitles) ...[
      {'Format': 'srt', 'Method': 'External'},
      {'Format': 'vtt', 'Method': 'External'},
    ],
  ],
};
