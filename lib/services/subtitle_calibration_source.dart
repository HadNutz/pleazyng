import 'dart:io';
import 'dart:typed_data';

import 'subtitle_calibration_history.dart';

/// The ephemeral sidecar binding passed from playback controls to calibration.
/// [uri] may contain a server access token and must never be logged or stored.
final class SubtitleCalibrationRequest {
  const SubtitleCalibrationRequest({
    required this.uri,
    required this.profileId,
    required this.serverId,
    required this.ratingKey,
    required this.mediaIndex,
    required this.partId,
    required this.partOffsetMs,
    required this.audioTrackIdentity,
    required this.subtitleTrackIdentity,
    required this.lane,
    this.extensionHint,
    required this.displayName,
    required this.isCurrent,
  });

  final Uri uri;
  final String profileId;
  final String serverId;
  final String ratingKey;
  final int mediaIndex;
  final String partId;
  final int partOffsetMs;
  final String audioTrackIdentity;
  final String subtitleTrackIdentity;
  final String lane;
  final String? extensionHint;
  final String displayName;
  final Future<bool> Function() isCurrent;

  String get extension {
    final pathExtension = uri.pathSegments.isEmpty ? '' : _extension(uri.pathSegments.last);
    return const {'.srt', '.vtt', '.ass', '.ssa'}.contains(pathExtension) ? pathExtension : extensionHint ?? '';
  }

  SubtitleCalibrationIdentity identityFor(List<int> sourceBytes) => SubtitleCalibrationIdentity(
    profileId: profileId,
    serverId: serverId,
    ratingKey: ratingKey,
    mediaIndex: mediaIndex,
    partId: partId,
    partOffsetMs: partOffsetMs,
    audioTrackIdentity: audioTrackIdentity,
    subtitleTrackIdentity: subtitleTrackIdentity,
    lane: lane,
    sourceBytesDigest: SubtitleCalibrationIdentity.digestBytes(sourceBytes),
  );

  static String _extension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot < 0 ? '' : fileName.substring(dot).toLowerCase();
  }
}

/// Reads only an explicitly selected sidecar, with strict byte/time limits.
/// Redirects are refused so an authenticated query token cannot be forwarded.
abstract final class SubtitleCalibrationSourceReader {
  static const int maximumBytes = 5 * 1024 * 1024;
  static const Duration maximumDuration = Duration(seconds: 20);

  static Future<Uint8List> read(Uri uri) async {
    if (!uri.isAbsolute || uri.userInfo.isNotEmpty) {
      throw const FormatException('The selected subtitle sidecar URI is invalid.');
    }
    if (uri.scheme == 'file') return _readFile(uri).timeout(maximumDuration);
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw const FormatException('Only a selected local or HTTP(S) text sidecar can be inspected.');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..autoUncompress = false;
    try {
      return await _readHttp(client, uri).timeout(maximumDuration);
    } finally {
      client.close(force: true);
    }
  }

  static Future<Uint8List> _readHttp(HttpClient client, Uri uri) async {
    final request = await client.getUrl(uri).timeout(const Duration(seconds: 5));
    request
      ..followRedirects = false
      ..maxRedirects = 0;
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != HttpStatus.ok) {
      throw const FormatException('The selected subtitle sidecar could not be read without a redirect.');
    }
    if (response.contentLength > maximumBytes) {
      throw const FormatException('The selected subtitle sidecar exceeds the 5 MiB read limit.');
    }
    final output = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 5))) {
      if (output.length + chunk.length > maximumBytes) {
        throw const FormatException('The selected subtitle sidecar exceeds the 5 MiB read limit.');
      }
      output.add(chunk);
    }
    final bytes = output.takeBytes();
    if (bytes.isEmpty) throw const FormatException('The selected subtitle sidecar is empty.');
    return bytes;
  }

  static Future<Uint8List> _readFile(Uri uri) async {
    final file = File.fromUri(uri);
    if (!await file.exists()) throw const FormatException('The selected subtitle sidecar is unavailable.');
    final before = await file.length();
    if (before <= 0 || before > maximumBytes) {
      throw const FormatException('The selected subtitle sidecar must be between 1 byte and 5 MiB.');
    }
    final output = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (output.length + chunk.length > maximumBytes) {
        throw const FormatException('The selected subtitle sidecar exceeds the 5 MiB read limit.');
      }
      output.add(chunk);
    }
    final bytes = output.takeBytes();
    final after = await file.length();
    if (bytes.length != before || after != before) {
      throw const FormatException('The selected subtitle sidecar changed while it was being read.');
    }
    return bytes;
  }
}
