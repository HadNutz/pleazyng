import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:video_player_drm/video_player.dart' as captions;

import '../../models.dart';
import 'subtitle_cue_timeline.dart';
import 'webos_media_proxy.dart';

/// System engines that cannot attach a sidecar still render SRT and WebVTT
/// in the same Flutter surface as the transport controls.
Future<SystemSubtitleTimeline> loadSystemSubtitles(SubtitleTrack track, Media media, WebOSMediaProxy? proxy) async {
  final uri = Uri.parse(track.uri!);
  final vtt = track.codec == 'vtt' || track.codec == 'webvtt' || uri.path.toLowerCase().endsWith('.vtt');
  final srt = track.codec == 'srt' || track.codec == 'subrip' || uri.path.toLowerCase().endsWith('.srt');
  if (!srt && !vtt) throw UnsupportedError('This video engine accepts SRT and WebVTT sidecars.');
  const limit = 2 * 1024 * 1024;
  HttpClient? client;
  try {
    final Stream<List<int>> stream;
    if (uri.scheme == 'file' || uri.scheme.isEmpty) {
      stream = (uri.scheme.isEmpty ? File(track.uri!) : File.fromUri(uri)).openRead(0, limit + 1);
    } else {
      if (uri.scheme != 'http' && uri.scheme != 'https') throw const FormatException('Unsupported subtitle URL');
      final source = Uri.tryParse(media.uri);
      final url =
          proxy?.register(
            uri,
            headers:
                source != null && (source.scheme == 'http' || source.scheme == 'https') && source.origin == uri.origin
                ? media.headers
                : null,
          ) ??
          uri;
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final response = await (await client.getUrl(url)).close().timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok) throw const HttpException('Subtitle download failed');
      stream = response;
    }
    final bytes = <int>[];
    await for (final chunk in stream.timeout(const Duration(seconds: 15))) {
      if (bytes.length + chunk.length > limit) throw const FormatException('Subtitle exceeds 2 MiB');
      bytes.addAll(chunk);
    }
    final text = utf8.decode(bytes).replaceFirst('\uFEFF', '');
    final cues = vtt ? captions.WebVTTCaptionFile(text).captions : captions.SubRipCaptionFile(text).captions;
    return SystemSubtitleTimeline(cues);
  } catch (_) {
    throw const FormatException('Subtitle file could not be read.');
  } finally {
    client?.close(force: true);
  }
}

class SystemSubtitleTimeline extends SubtitleCueTimeline {
  SystemSubtitleTimeline(Iterable<captions.Caption> source)
    : super(source.map((cue) => (start: cue.start, end: cue.end, text: cue.text)));
}
