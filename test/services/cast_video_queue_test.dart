import 'package:flutter/services.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_part_timeline.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/services/cast_video_queue.dart';
import 'package:plezy/services/music/cast_music_queue.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import '../test_helpers/music_experience_fakes.dart';
import '../test_helpers/media_items.dart';

class _MovieClient extends ExperienceClient {
  final requests = <(Duration?, bool, String?)>[];
  bool loseSecond = false;
  List<SubtitleTrack> captions = const [];

  @override
  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
    bool registerPlayback = true,
  }) async {
    requests.add((position, registerPlayback, mediaSourceId));
    const parts = [MediaPart(id: 'one', durationMs: 3000000), MediaPart(id: 'two', durationMs: 2400000)];
    final index = position! < const Duration(minutes: 50) ? 0 : 1;
    return loseSecond && index == 1
        ? null
        : ExternalPlaybackTarget(
            url: index == 0
                ? 'https://server/part0.mp4?X-Plex-Client-Identifier=phone&X-Plex-Session-Identifier=session0'
                : 'https://server/part1.mp4?tag=a&tag=b',
            playSessionId: 'session$index',
            partTimeline: MediaPartTimeline.fromParts(parts, currentIndex: index),
            subtitles: captions,
          );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a 50+40 minute Plex movie queues both files and keeps item-time boundaries', () async {
    final client = _MovieClient();
    final parts = await prepareCastVideoParts(
      client: client,
      item: testMediaItem(id: 'movie'),
      mediaIndex: 0,
      mediaSourceId: 'edition',
      position: const Duration(minutes: 40),
      token: 'owner',
      selectedSubtitle: SubtitleTrack.off,
      current: () => true,
    );
    expect(client.requests, [
      (const Duration(minutes: 40), true, 'edition'),
      (const Duration(minutes: 50), false, 'edition'),
    ]);
    expect(parts.map((e) => e.end?.inMinutes), [50, 90]);
    expect(parts.first.hasNext, isTrue);
    expect(parts.last.hasNext, isFalse);
    expect(parts.first.itemPosition(const Duration(minutes: 51)).inMinutes, 50);
    expect(parts.last.itemPosition(const Duration(minutes: 2)).inMinutes, 52);
    expect(parts.last.itemPosition(const Duration(minutes: 40)).inMinutes, 90);
    expect(parts.last.start.inMinutes, 50);
    final secondUrl = parts.last.item.mediaInformation.contentUrl!;
    expect(secondUrl.queryParameters['X-Plex-Session-Identifier'], 'session0');
    expect(secondUrl.queryParameters['X-Plex-Client-Identifier'], 'phone');
    expect(secondUrl.queryParametersAll['tag'], ['a', 'b']);
    expect(parts.map((e) => e.item.autoPlay), [false, true]);
    expect(parts.map((e) => e.item.mediaInformation.customData?['pleazyngPart']), ['0', '1']);
    expect(parts.last.item.mediaInformation.duration?.inMinutes, 40);
  });
  for (final android in [true, false]) {
    test(
      'the ${android ? 'Android' : 'iOS'} queue bridge receives per-part playback and caption instructions',
      () async {
        final es = SubtitleTrack.uri('https://server/spanish.vtt', language: 'spa');
        final client = _MovieClient()
          ..captions = [SubtitleTrack.uri('https://server/english.vtt', language: 'en', isDefault: true), es];
        final parts = await prepareCastVideoParts(
          client: client,
          item: testMediaItem(id: 'movie'),
          mediaIndex: 0,
          mediaSourceId: null,
          position: const Duration(minutes: 40),
          token: 'owner',
          selectedSubtitle: es,
          current: () => true,
        );
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final channel = MethodChannel(
          android ? 'com.felnanuke.google_cast.remote_media_client' : 'google_cast.remote_media_client',
        );
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await dispatchCastQueue(
          parts.map((part) => part.item).toList(),
          GoogleCastQueueLoadOptions(
            startIndex: 0,
            playPosition: const Duration(minutes: 40),
            repeatMode: GoogleCastMediaRepeatMode.off,
          ),
          android: android,
        );
        final call = calls.single;
        expect(call.method, 'queueLoadItems');
        expect(call.arguments['options']['playPosition'], 2400);
        final items = call.arguments[android ? 'queueItems' : 'items'] as List;
        for (final (index, item) in items.indexed) {
          expect(item[android ? 'autoPlay' : 'autoplay'], index == 1);
          expect(item['activeTrackIds'], [2]);
          expect(item['media']['customData'], {'pleazyngOwner': 'owner', 'pleazyngPart': '$index'});
          final track = item['media']['tracks'][1];
          expect(track['trackContentType'], 'text/vtt');
          expect(track['language'], 'es');
        }
      },
    );
  }

  test('a missing later file rejects preparation before the receiver is replaced', () async {
    final client = _MovieClient()..loseSecond = true;
    await expectLater(
      prepareCastVideoParts(
        client: client,
        item: testMediaItem(id: 'movie'),
        mediaIndex: 0,
        mediaSourceId: null,
        position: Duration.zero,
        token: 'owner',
        selectedSubtitle: SubtitleTrack.off,
        current: () => true,
      ),
      throwsStateError,
    );
  });
  test('an explicit off or Spanish selection overrides the default English sidecar', () {
    final en = SubtitleTrack.uri('https://server/english.vtt', language: 'en', isDefault: true);
    final es = SubtitleTrack.uri('https://server/spanish.ttml', language: 'es');
    final file = Uri.parse('https://server/movie.mp4');
    final tracks = castVideoCaptions([en, es], es, file, MediaBackend.plex);
    expect(tracks.active, [2]);
    expect(tracks.tracks.last.trackContentType, 'application/ttml+xml');
    expect(castVideoCaptions([en, es], SubtitleTrack.off, file, MediaBackend.plex).active, isEmpty);
  });
  test('subtitle conversion requests preserve server auth and omit unsupported foreign SRT', () {
    for (final backend in [MediaBackend.plex, MediaBackend.jellyfin, MediaBackend.emby]) {
      final path = backend == MediaBackend.plex
          ? '/library/streams/11.srt?X-Plex-Token=key'
          : '/Videos/item/src/Subtitles/1/Stream.srt?Format=srt&ApiKey=key';
      final track = SubtitleTrack.uri('https://server$path', codec: 'srt', language: 'es');
      final file = Uri.parse('https://server/movie.mp4');
      final result = castVideoCaptions([track], track, file, backend);
      expect(result.active, [1]);
      final uri = Uri.parse(result.tracks.single.trackContentId!);
      expect(result.tracks.single.trackContentType, 'text/vtt');
      expect(uri.queryParameters[backend == MediaBackend.plex ? 'X-Plex-Token' : 'ApiKey'], 'key');
      if (backend == MediaBackend.plex) {
        expect(uri.queryParameters['format'], 'webvtt');
      } else {
        expect(uri.path, endsWith('/Stream.vtt'));
        expect(uri.queryParameters['format'], 'vtt');
      }
      final foreign = SubtitleTrack.uri('https://provider/signed.srt', codec: 'srt');
      expect(() => castVideoCaptions([foreign], foreign, file, backend), throwsStateError);
    }
  });
}
