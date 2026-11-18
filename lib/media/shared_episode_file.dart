import 'media_item.dart';
import 'media_item_types.dart';
import 'media_version.dart';

/// Only original, single-file versions can share a download. A title, runtime,
/// filename basename, or a part id from a different episode is insufficient.
bool sameSelectedEpisodeFile(MediaItem requested, MediaVersion? selected, MediaItem cached, MediaVersion? stored) {
  if (!requested.isEpisode ||
      !cached.isEpisode ||
      requested.serverId != cached.serverId ||
      requested.backend != cached.backend ||
      requested.parentId == null ||
      requested.parentId != cached.parentId ||
      selected == null ||
      stored == null ||
      selected.parts.length != 1 ||
      stored.parts.length != 1) {
    return false;
  }
  final a = selected.parts.single, b = stored.parts.single;
  return a.file != null &&
      a.file!.isNotEmpty &&
      a.file == b.file &&
      a.sizeBytes != null &&
      a.sizeBytes! > 0 &&
      a.sizeBytes == b.sizeBytes &&
      a.durationMs != null &&
      a.durationMs! > 0 &&
      a.durationMs == b.durationMs;
}
