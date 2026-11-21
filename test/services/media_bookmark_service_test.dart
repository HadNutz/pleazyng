import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/services/jellyfin_media_info_mapper.dart';
import 'package:plezy/services/plex_mappers.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/media_bookmark_service.dart';

import 'package:plezy/media/media_version.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  test('bookmarks follow a cut across reordering and legacy assignment is explicit', () async {
    final item = testMediaItem(id: 'movie', serverId: 'server', durationMs: 7200000);
    const long = MediaVersion(id: 'extended'), short = MediaVersion(id: 'theatrical');
    final key = MediaBookmarkService.timelineKey(item, [long, short], 0)!;
    expect(MediaBookmarkService.timelineKey(item, [short, long], 1), key);
    final other = MediaBookmarkService.timelineKey(item, [short, long], 0)!;
    expect(other, isNot(key));
    await MediaBookmarkService.add(key, 'Long cut epilogue', 6600000);
    final old = await MediaBookmarkService.add(item.globalKey, 'Legacy mark', 46000);
    expect(MediaBookmarkService.forMedia(other), isEmpty);
    await MediaBookmarkService.assignToVersion(item.globalKey, other, old.id);
    expect(MediaBookmarkService.forMedia(item.globalKey), isEmpty);
    expect(MediaBookmarkService.forMedia(other).single.id, old.id);
    expect(MediaBookmarkService.forMedia(key).single.positionMs, 6600000);
    expect(
      MediaBookmarkService.timelineKey(item, [], 0),
      isNot(MediaBookmarkService.timelineKey(item.copyWith(durationMs: 5400000), [], 0)),
    );
  });

  for (final backend in [MediaBackend.jellyfin, MediaBackend.emby]) {
    test('$backend bookmarks ignore playback ordinals, including cached versions', () {
      final item = testMediaItem(backend: backend);
      final long = {'Name': 'Director cut', 'Path': '/films/long.mkv', 'RunTimeTicks': 72000000000};
      final short = {'Name': 'Cinema cut', 'Path': '/films/short.mkv', 'RunTimeTicks': 54000000000};
      final versions = jellyfinSourcesToVersions([long, short]);
      final reordered = jellyfinSourcesToVersions([short, long]).map((v) => MediaVersion.fromJson(v.toJson())).toList();
      expect(versions.first.id, reordered.first.id, reason: 'the mapper supplies the ordinal on both calls');
      final key = MediaBookmarkService.timelineKey(item, versions, 0);
      expect(key, isNotNull);
      expect(MediaBookmarkService.timelineKey(item, reordered, 1), key);
      expect(MediaBookmarkService.timelineKey(item, reordered, 0), isNot(key));

      final indistinguishable = jellyfinSourcesToVersions([long, long]);
      expect(MediaBookmarkService.timelineKey(item, indistinguishable, 0), isNull);
      expect(MediaBookmarkService.timelineKey(item, indistinguishable, 1), isNull);
    });
  }

  test('missing Plex media and part ids use distinguishable files or decline an ambiguous bookmark', () {
    final item = testMediaItem();
    MediaVersion fromPart(Map<String, dynamic> part) => PlexMappers.mediaVersion(
      PlexMediaVersionDto.fromJson({
        'Part': [part],
      }),
    );
    final short = fromPart({'file': '/films/short.mkv'}), long = fromPart({'file': '/films/long.mkv'});
    expect(short.id, '0');
    expect(short.parts.single.id, '0');
    final key = MediaBookmarkService.timelineKey(item, [long, short], 0);
    expect(key, isNotNull);
    expect(MediaBookmarkService.timelineKey(item, [short, long], 1), key);
    expect(MediaBookmarkService.timelineKey(item, [short, long], 0), isNot(key));

    final anonymous = fromPart({});
    expect(MediaBookmarkService.timelineKey(item, [anonymous, anonymous], 0), isNull);
    final first = fromPart({'id': 15}), second = fromPart({'id': 19});
    final explicitPartKey = MediaBookmarkService.timelineKey(item, [first, second], 0);
    expect(explicitPartKey, isNotNull);
    expect(MediaBookmarkService.timelineKey(item, [second, first], 1), explicitPartKey);
    expect(MediaBookmarkService.timelineKey(item, [second, first], 0), isNot(explicitPartKey));
  });

  test('stores a normalized local mark and removes its item when the last mark is deleted', () async {
    final saved = await MediaBookmarkService.add('open-media:opaque-hash', '  Best scene  ', 42000);

    expect(saved.label, 'Best scene');
    expect(saved.positionMs, 42000);
    final marks = MediaBookmarkService.forMedia('open-media:opaque-hash');
    expect(marks, hasLength(1));
    expect(marks.single.id, saved.id);
    expect(marks.single.label, saved.label);
    expect(marks.single.positionMs, saved.positionMs);
    expect(() => marks.clear(), throwsUnsupportedError);

    await MediaBookmarkService.remove('open-media:opaque-hash', saved.id);
    expect(MediaBookmarkService.forMedia('open-media:opaque-hash'), isEmpty);
    expect(SettingsService.instance.read(SettingsService.mediaBookmarks), isEmpty);
  });

  test('rejects invalid marks and enforces the per-item limit', () async {
    for (final (label, position) in [(' ', 0), ('valid', -1), (List.filled(81, 'x').join(), 0)]) {
      await expectLater(MediaBookmarkService.add('movie', label, position), throwsA(isA<ArgumentError>()));
    }

    for (var index = 0; index < MediaBookmarkService.maxBookmarksPerItem; index++) {
      await MediaBookmarkService.add('movie', 'Mark $index', index * 1000);
    }
    expect(MediaBookmarkService.forMedia('movie'), hasLength(MediaBookmarkService.maxBookmarksPerItem));
    await expectLater(
      MediaBookmarkService.add('movie', 'One too many', 999999),
      throwsA(isA<MediaBookmarkLimitException>()),
    );
  });
}
