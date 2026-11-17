import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:video_player_drm/video_player.dart' as captions;

import '../../models.dart';
import 'webos_media_proxy.dart';

/// System engines that cannot attach a sidecar still render SRT and WebVTT
/// in the same Flutter surface as the transport controls.
Future<List<captions.Caption>> loadSystemSubtitles(SubtitleTrack track, Media media, WebOSMediaProxy? proxy) async {
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
    return cues.toList()..sort((a, b) => a.start.compareTo(b.start));
  } catch (_) {
    throw const FormatException('Subtitle file could not be read.');
  } finally {
    client?.close(force: true);
  }
}

String systemCaptionAt(List<captions.Caption> cues, Duration position) {
  var lo = 0, hi = cues.length;
  while (lo < hi) {
    final mid = (lo + hi) ~/ 2;
    if (cues[mid].start <= position) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  if (lo == 0) return '';
  final cue = cues[lo - 1];
  return position < cue.end ? cue.text : '';
}
