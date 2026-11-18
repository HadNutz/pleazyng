import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:os_media_controls/os_media_controls.dart';
import 'package:os_media_controls/os_media_controls_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/companion_remote/phone_listening_screen.dart';
import 'package:plezy/services/companion_remote/listening_clock.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import '../../test_helpers/media_items.dart';

const _file = (server: 'server', item: 'movie', source: 'edition', part: 4);

class _Headphones extends OsMediaControlsPlatform {
  final events = StreamController<MediaControlEvent>.broadcast(sync: true);
  @override
  Stream<MediaControlEvent> get controlEvents => events.stream;
  Future<void> close() => events.close();
}

class _Remote extends Fake with ChangeNotifier implements CompanionRemoteProvider {
  ListeningClock? sample = const ListeningClock(_file, Duration(seconds: 7), true, 1);
  @override
  bool get supportsPhoneListening => true;
  @override
  bool get isPlayerActive => true;
  @override
  Future<ListeningClock?> sampleListeningClock() async => sample;
}

class _Profile extends Fake with ChangeNotifier implements ActiveProfileProvider {
  @override
  String get activeId => 'viewer';
}

class _Server extends Fake implements MediaServerClient {
  @override
  ServerId get serverId => ServerId('server');
  @override
  Future<MediaItem?> fetchItem(String id) async => testMediaItem(id: id, title: 'Movie');
  int part = 4;
  @override
  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
    bool registerPlayback = true,
  }) async {
    expect(registerPlayback, isFalse);
    expect(mediaSourceId, 'edition');
    return ExternalPlaybackTarget(
      url: 'https://server/movie',
      mediaInfo: MediaSourceInfo(
        videoUrl: 'https://server/movie',
        partId: part,
        mediaSourceId: mediaSourceId,
        audioTracks: [
          MediaAudioTrack(id: 22, index: 2, selected: false, described: true, title: 'Narrated soundtrack'),
        ],
        chapters: [],
        subtitleTracks: [],
      ),
    );
  }
}

class _Manager extends Fake implements MultiServerManager {
  _Manager(this.client);
  final _Server client;
  @override
  Map<String, MediaServerClient> get visibleOnlineClients => {'server': client};
  @override
  bool isRemoteConnection(ServerId serverId) => false;
}

class _Servers extends Fake with ChangeNotifier implements MultiServerProvider {
  _Servers(this.serverManager);
  @override
  final MultiServerManager serverManager;
}

class _Streams extends Fake implements PlayerStreams {
  final loaded = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get fileLoaded => loaded.stream;
  @override
  Stream<void> get fileLoadFailed => failed.stream;
  final failed = StreamController<void>.broadcast(sync: true);
  Future<void> close() async {
    await Future.wait([loaded.close(), failed.close()]);
  }
}

class _Audio extends Fake implements Player {
  @override
  final _Streams streams = _Streams();
  @override
  PlayerState state = const PlayerState();
  @override
  Duration currentPosition = Duration.zero;
  String? aid;
  @override
  bool disposed = false;
  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) async {
    expect(play, isFalse);
    expect(media.uri, 'https://server/movie');
    streams.loaded.add(null);
  }

  @override
  Future<String?> getProperty(String name) async => {
    'aid': aid,
    'track-list/count': '2',
    'track-list/0/type': 'audio',
    'track-list/0/id': '1',
    'track-list/0/title': 'Main audio',
    'track-list/0/ff-index': '1',
    'track-list/1/type': 'audio',
    'track-list/1/id': '2',
    'track-list/1/ff-index': '2',
  }[name];
  @override
  Future<void> selectAudioTrack(AudioTrack track) async {
    aid = track.id;
  }

  @override
  Future<void> play() async {
    expect(aid, isNotNull);
    state = state.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    currentPosition = position;
  }

  @override
  Future<void> setRate(double rate) async {
    state = state.copyWith(rate: rate);
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    disposed = true;
    await streams.close();
  }
}

void main() {
  for (final exactEdition in [true, false]) {
    testWidgets(
      exactEdition
          ? 'private description follows TV seeks, pauses, track changes and lost replies'
          : 'a mismatched part never opens the phone player',
      (tester) async {
        final system = OsMediaControlsPlatform.instance;
        final headphones = _Headphones();
        OsMediaControlsPlatform.instance = headphones;
        addTearDown(() async {
          OsMediaControlsPlatform.instance = system;
          await headphones.close();
        });
        final server = _Server(), remote = _Remote(), player = _Audio();
        if (!exactEdition) server.part = 8;
        var opens = 0;
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<CompanionRemoteProvider>.value(value: remote),
              ChangeNotifierProvider<MultiServerProvider>.value(value: _Servers(_Manager(server))),
              ChangeNotifierProvider<ActiveProfileProvider>.value(value: _Profile()),
            ],
            child: MaterialApp(
              home: PhoneListeningScreen(
                createPlayer: () {
                  opens++;
                  return player;
                },
              ),
            ),
          ),
        );
        Future<void> tick() async {
          await tester.pump(const Duration(milliseconds: 310));
          await tester.pump();
        }

        await tick();
        await tick();
        if (!exactEdition) {
          expect(opens, 0);
          expect(player.aid, isNull);
        } else {
          expect(opens, 1);
          expect(player.aid, '2');
          expect(player.state.playing, isTrue);
          remote.sample = const ListeningClock(_file, Duration(seconds: 75), false, 1);
          await tick();
          expect(player.state.playing, isFalse);
          expect(player.currentPosition, const Duration(seconds: 75));
          await tester.tap(find.text('Main audio'));
          remote.sample = const ListeningClock(_file, Duration(seconds: 41), true, 1.5);
          await tick();
          expect(player.aid, '1');
          expect(player.state.rate, 1.5);
          expect(player.currentPosition.inSeconds, 41);
          headphones.events.add(const AudioRouteOldDeviceUnavailableEvent());
          await tick();
          expect(player.state.playing, isFalse);
          remote.sample = const ListeningClock(_file, Duration(seconds: 63), true, 1.0);
          await tick();
          expect(player.state.playing, isFalse);
          headphones.events.add(const AudioRouteNewDeviceAvailableEvent());
          await tick();
          expect(player.state.playing, isTrue);
          expect(player.currentPosition.inSeconds, 63);
          remote.sample = null;
          await tick();
          expect(player.state.playing, isFalse);
          remote.sample = const ListeningClock(_file, Duration(seconds: 50), true, 1);
          await tick();
          expect(player.state.playing, isTrue);
          expect(opens, 1);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        if (exactEdition) {
          expect(player.disposed, isTrue);
        } else {
          await player.streams.close();
        }
      },
    );
  }
}
