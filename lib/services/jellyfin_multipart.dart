import '../media/media_part.dart';
import '../media/media_part_timeline.dart';
import '../utils/jellyfin_time.dart';
import '../utils/json_utils.dart';

/// Full detail DTOs for the ordered children returned by AdditionalParts.
/// Kept in the account-scoped item cache so downloaded playback needs no server.
const jellyfinAdditionalPartDetails = 'PleazyngAdditionalPartDetails';

class JellyfinVideoPart {
  final String itemId;
  final Map<String, dynamic> source;
  final Map<String, dynamic> item;
  final MediaPart part;
  JellyfinVideoPart(this.item, this.source)
    : itemId = item['Id'] as String,
      part = MediaPart(
        id: item['Id'] as String,
        file: source['Path'] as String?,
        container: source['Container'] as String?,
        durationMs: jellyfinTicksToMs(source['RunTimeTicks'] ?? item['RunTimeTicks']),
        sizeBytes: flexibleInt(source['Size']),
      );

  String? get sourceId => source['Id'] as String?;
}

class JellyfinMultipart {
  final List<JellyfinVideoPart> files;
  final List<MediaPart> parts;
  final MediaPartTimeline timeline;
  JellyfinMultipart._(this.files, this.parts, this.timeline);

  /// AdditionalParts is attached to the primary video item, not every alternate cut.
  static JellyfinMultipart? fromItem(Map<String, dynamic> raw, int index) {
    final count = flexibleInt(raw['PartCount']) ?? 1;
    if (count < 2) return null;
    final roots = raw['MediaSources'];
    if (roots is! List || index < 0 || index >= roots.length) return null;
    final ownIndex = roots.indexWhere((s) => s is Map && s['Id'] == raw['Id']);
    if (index != (ownIndex < 0 ? 0 : ownIndex)) return null;
    final children = raw[jellyfinAdditionalPartDetails];
    if (children is! List || children.length != count - 1) {
      throw const FormatException('Incomplete MediaBrowser video parts');
    }
    final root = roots[index] as Map<String, dynamic>;
    final files = [JellyfinVideoPart(raw, root)];
    final ids = {raw['Id']};
    for (final child in children.whereType<Map<String, dynamic>>()) {
      final id = child['Id'];
      final sources = child['MediaSources'];
      if (id is! String || id.isEmpty || !ids.add(id) || sources is! List || sources.isEmpty) {
        throw const FormatException('Invalid MediaBrowser video part');
      }
      final matches = sources.whereType<Map<String, dynamic>>();
      final source = matches.where((row) => row['Id'] == id).firstOrNull ?? matches.firstOrNull;
      if (source == null) throw const FormatException('Missing MediaBrowser part source');
      files.add(JellyfinVideoPart(child, source));
    }
    final parts = [for (final file in files) file.part];
    final timeline = MediaPartTimeline.fromParts(parts);
    if (files.length != count || timeline == null) throw const FormatException('Missing MediaBrowser part duration');
    return JellyfinMultipart._(files, parts, timeline);
  }

  MediaPartTimeline at(Duration? position) =>
      MediaPartTimeline.fromParts(parts, currentIndex: timeline.indexAt(position ?? Duration.zero))!;

  int get resumeMs {
    var resume = 0;
    for (final (index, file) in files.indexed) {
      final user = file.item['UserData'];
      if (user is! Map) continue;
      final span = timeline.parts[index];
      final ms = jellyfinTicksToMs(user['PlaybackPositionTicks']) ?? 0;
      if (ms > 0) return span.start.inMilliseconds + ms.clamp(0, span.duration.inMilliseconds);
      if (user['Played'] == true && resume == span.start.inMilliseconds) resume = span.end.inMilliseconds;
    }
    return resume >= timeline.duration.inMilliseconds ? 0 : resume;
  }
}
