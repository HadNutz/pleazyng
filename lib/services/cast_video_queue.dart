import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_server_client.dart';
import '../mpv/models.dart';
import '../utils/language_codes.dart';
import 'playback_initialization_types.dart';
import 'plex_direct_play_identity.dart';
import 'subtitle_preference.dart';
import 'track_selection_service.dart';

/// The receiver reports a file-relative position. Keep the part boundary and
/// server identity with the exact queue entry that supplied that position.
class CastVideoPart {
  const CastVideoPart(this.target, this.start, this.end, this.item);
  final ExternalPlaybackTarget target;
  final Duration start;
  final Duration? end;
  final GoogleCastQueueItem item;

  bool get hasNext => target.partTimeline?.hasNext == true;

  Duration itemPosition(Duration receiverPosition) {
    final position = start + receiverPosition;
    if (position < start) return start;
    final boundary = end;
    return boundary != null && position > boundary ? boundary : position;
  }
}

Future<List<CastVideoPart>> prepareCastVideoParts({
  required MediaServerClient client,
  required MediaItem item,
  required int mediaIndex,
  required String? mediaSourceId,
  required Duration position,
  required String token,
  required SubtitleTrack selectedSubtitle,
  required bool Function() current,
}) async {
  Future<ExternalPlaybackTarget> resolve(Duration at, {required bool register}) async {
    if (!current()) throw StateError('Video handoff changed');
    final target = await client.resolveExternalPlayback(
      item,
      mediaIndex: mediaIndex,
      mediaSourceId: mediaSourceId,
      position: at,
      registerPlayback: register,
    );
    if (!current() || target == null) throw StateError('Cast source unavailable');
    return target;
  }

  final first = await resolve(position, register: true);
  final timeline = first.partTimeline;
  if (timeline != null && !timeline.covers(position)) throw StateError('Requested Cast part unavailable');
  final parts = <CastVideoPart>[];
  final count = timeline == null ? 1 : timeline.parts.length - timeline.currentIndex;
  for (var i = 0; i < count; i++) {
    final span = timeline == null ? null : timeline.parts[timeline.currentIndex + i];
    final target = i == 0 ? first : await resolve(span!.start, register: false);
    if (span != null &&
        (target.partTimeline?.current.partId != span.partId ||
            target.partTimeline?.current.start != span.start ||
            target.partTimeline?.current.end != span.end)) {
      throw StateError('The movie parts changed during Cast preparation');
    }
    var uri = Uri.tryParse(target.url);
    if (uri == null || !{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      throw StateError('No receiver-accessible Cast URL');
    }
    if (i > 0 && client.backend == MediaBackend.plex && first.playSessionId != null) {
      final registered = Uri.parse(first.url);
      final clientId = registered.queryParameters['X-Plex-Client-Identifier'];
      if (uri.origin == registered.origin && clientId != null) {
        uri = Uri.parse(plexDirectPlayIdentity(target.url, clientId: clientId, sessionId: first.playSessionId!));
      }
    }
    final candidates = [...target.subtitles];
    final info = target.mediaInfo;
    if (client.backend.usesMediaBrowserApi && info != null) {
      final fileItem = span == null || span.partId == item.id ? item : item.copyWith(id: span.partId);
      for (final row in info.subtitleTracks.where((r) => !r.isExternalFile)) {
        final sidecar = client.buildPlaybackSubtitleSidecar(fileItem, row, mediaSourceId: info.mediaSourceId);
        if (sidecar != null) candidates.add(sidecar.track);
      }
    }
    final captions = castVideoCaptions(candidates, selectedSubtitle, uri, client.backend);
    final duration = span?.duration ?? (item.durationMs == null ? null : Duration(milliseconds: item.durationMs!));
    final information = GoogleCastMediaInformation(
      contentId: uri.toString(),
      contentUrl: uri,
      contentType: castVideoContentType(uri),
      streamType: CastMediaStreamType.buffered,
      duration: duration,
      metadata: GoogleCastGenericMediaMetadata(title: item.displayTitle, subtitle: item.displaySubtitle),
      tracks: captions.tracks.isEmpty ? null : captions.tracks,
      customData: {'pleazyngOwner': token, 'pleazyngPart': '$i'},
    );
    parts.add(
      CastVideoPart(
        target,
        span?.start ?? Duration.zero,
        span?.end ?? duration,
        GoogleCastQueueItem(autoPlay: i != 0, mediaInformation: information, activeTrackIds: captions.active),
      ),
    );
  }
  return parts;
}

({List<GoogleCastMediaTrack> tracks, List<int> active}) castVideoCaptions(
  List<SubtitleTrack> candidates,
  SubtitleTrack selected,
  Uri media,
  MediaBackend backend,
) {
  final intent = SubtitleIntent.fromTrack(selected);
  final selectedTrack = selected.id == SubtitleTrack.off.id
      ? null
      : selected.id == SubtitleTrack.auto.id
      ? candidates.where((row) => row.isDefault).firstOrNull
      : candidates.where((row) => row.id == selected.id || (row.uri != null && row.uri == selected.uri)).firstOrNull ??
            (intent == null ? null : findNativeTrackForIntent(intent, candidates));
  final tracks = <GoogleCastMediaTrack>[];
  final active = <int>[];
  for (final row in candidates) {
    final uri = Uri.tryParse(row.uri ?? '');
    if (uri == null || !{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) continue;
    final ext = uri.pathSegments.lastOrNull?.split('.').last.toLowerCase();
    var output = uri;
    String type;
    final codec = row.codec?.toLowerCase();
    final hasExtension = uri.pathSegments.lastOrNull?.contains('.') ?? false;
    if (ext == 'vtt' || ext == 'webvtt' || (!hasExtension && codec == 'webvtt')) {
      type = 'text/vtt';
    } else if (ext == 'ttml' || ext == 'dfxp' || (!hasExtension && codec == 'ttml')) {
      type = 'application/ttml+xml';
    } else if (const {'srt', 'subrip', 'ass', 'ssa', 'mov_text'}.contains(row.codec?.toLowerCase()) ||
        const {'srt', 'ass', 'ssa'}.contains(ext)) {
      if (uri.origin != media.origin) continue;
      if (backend.usesMediaBrowserApi &&
          RegExp(r'/Subtitles/\d+/(?:\d+/)?Stream\.\w+$', caseSensitive: false).hasMatch(uri.path)) {
        output = uri.replace(path: uri.path.replaceFirst(RegExp(r'\.\w+$'), '.vtt'));
        if (uri.queryParameters.keys.any((key) => key.toLowerCase() == 'format')) {
          output = _subtitleFormat(output, 'vtt');
        }
      } else if (backend == MediaBackend.plex && RegExp(r'/library/streams/\d+(?:\.\w+)?$').hasMatch(uri.path)) {
        output = _subtitleFormat(uri.replace(path: uri.path.replaceFirst(RegExp(r'\.\w+$'), '')), 'webvtt');
      } else {
        continue;
      }
      type = 'text/vtt';
    } else {
      continue;
    }
    final id = tracks.length + 1;
    final tag = row.language?.toLowerCase().replaceAll('_', '-');
    final iso = LanguageCodes.getIso6391Code(tag ?? '');
    final language =
        Rfc5646Language.values.where((lang) => lang.value.toLowerCase() == tag).firstOrNull ??
        Rfc5646Language.values.where((lang) => lang.value == iso).firstOrNull;
    tracks.add(
      GoogleCastMediaTrack(
        trackId: id,
        type: TrackType.text,
        subtype: TextTrackType.subtitles,
        trackContentId: output.toString(),
        trackContentType: type,
        name: row.title ?? row.language,
        language: language,
      ),
    );
    if (identical(row, selectedTrack)) active.add(id);
  }
  if (selected.id != SubtitleTrack.off.id && selected.id != SubtitleTrack.auto.id && active.isEmpty) {
    throw StateError('The receiver cannot play the selected caption');
  }
  return (tracks: tracks, active: active);
}

Uri _subtitleFormat(Uri uri, String format) {
  final fields = uri.query.split('&').where((field) {
    final name = field.split('=').first;
    return name.isNotEmpty && Uri.decodeQueryComponent(name).toLowerCase() != 'format';
  });
  return uri.replace(query: [...fields, 'format=$format'].join('&'));
}

String castVideoContentType(Uri uri) {
  final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last.toLowerCase();
  if (name.endsWith('.m3u8')) return 'application/x-mpegURL';
  if (name.endsWith('.mpd')) return 'application/dash+xml';
  if (name.endsWith('.webm')) return 'video/webm';
  if (name.endsWith('.mov')) return 'video/quicktime';
  if (name.endsWith('.mkv')) return 'video/x-matroska';
  if (name.endsWith('.ts')) return 'video/mp2t';
  if (name.endsWith('.mp3')) return 'audio/mpeg';
  if (name.endsWith('.m4a')) return 'audio/mp4';
  return 'video/mp4';
}
