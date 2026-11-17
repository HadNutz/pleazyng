import 'codec_catalog.dart';
import 'media_source_info.dart';
import 'media_version.dart';

/// Whether a Plex source fits the formats already advertised by the native
/// Samsung profile. Unknown dimensions or audio formats retain conversion.
bool tizenCanDirectPlayVideo(MediaVersion? version, MediaSourceInfo? source) {
  if (version == null || source == null) return false;
  if (!const {'mp4', 'm4v'}.contains(version.container?.toLowerCase()) ||
      CodecCatalog.normalize(version.videoCodec ?? '') != 'h264') {
    return false;
  }
  final width = version.width;
  final height = version.height;
  if (width == null || height == null || width <= 0 || height <= 0 || width > 1920 || height > 1080) return false;
  final criteria = source.displayCriteria;
  if ((criteria?.bitDepth ?? 0) > 8 || (criteria?.fps ?? 0) > 60 || criteria?.isHdr == true) return false;
  return source.audioTracks.every(
    (track) =>
        const {'aac', 'mp3'}.contains(track.codec?.toLowerCase()) &&
        track.channels != null &&
        track.channels! > 0 &&
        track.channels! <= 2,
  );
}

/// Conservative profile for the unqualified Samsung native-media port.
/// Expand only after exercising a model/firmware combination on hardware.
Map<String, Object?> tizenPlaybackProfile({required bool audio, required bool burnSubtitles}) => {
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
    {'Type': 'Video', 'Container': 'mp4,m4v', 'VideoCodec': 'h264', 'AudioCodec': 'aac,mp3'},
    if (audio) {'Type': 'Audio', 'Container': 'mp3,aac,m4a,m4b', 'AudioCodec': 'mp3,aac'},
  ],
  'CodecProfiles': [
    {
      'Type': 'Video',
      'Codec': 'h264',
      'Conditions': [
        {'Condition': 'LessThanEqual', 'Property': 'Width', 'Value': '1920', 'IsRequired': true},
        {'Condition': 'LessThanEqual', 'Property': 'Height', 'Value': '1080', 'IsRequired': true},
        {'Condition': 'LessThanEqual', 'Property': 'VideoBitDepth', 'Value': '8', 'IsRequired': false},
        {'Condition': 'LessThanEqual', 'Property': 'VideoFramerate', 'Value': '60', 'IsRequired': false},
      ],
    },
    {
      'Type': 'VideoAudio',
      'Codec': 'aac,mp3',
      'Conditions': [
        {'Condition': 'LessThanEqual', 'Property': 'AudioChannels', 'Value': '2', 'IsRequired': true},
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

/// Keep lower quality choices, while capping Original/4K on this initial port.
String tizenVideoResolution(String? requested) {
  final dimensions = requested?.split('x').map(int.tryParse).toList();
  if (dimensions?.length == 2 &&
      dimensions![0] != null &&
      dimensions[1] != null &&
      dimensions[0]! > 0 &&
      dimensions[1]! > 0 &&
      dimensions[0]! <= 1920 &&
      dimensions[1]! <= 1080) {
    return requested!;
  }
  return '1920x1080';
}
