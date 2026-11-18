import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/services/movie_audio_attachment.dart';
import '../test_helpers/io_fakes.dart';

class _Player implements Player {
  final properties = <String, String>{'aid': '1', 'audio-delay': '0.2', 'audio-spdif': 'ac3,dts', 'lavfi-complex': ''};
  final commands = <List<String>>[];
  final seeks = <Duration>[];
  int plays = 0;
  bool rejectMix = false;
  String? external;
  void Function()? onAudioAdd;
  @override
  PlayerState get state => const PlayerState(playing: true, position: Duration(seconds: 2));
  @override
  Duration get currentPosition => state.position;
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {
    plays++;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
  }

  @override
  Future<String?> getProperty(String key) async => switch (key) {
    'track-list/count' => external == null ? '1' : '2',
    'track-list/1/external-filename' => external,
    'track-list/1/id' => '2',
    _ => properties[key],
  };
  @override
  Future<void> setProperty(String key, String value) async {
    key = key.replaceFirst('file-local-options/', '');
    if (key == 'lavfi-complex' && value.isNotEmpty && rejectMix) throw StateError('unsupported graph');
    properties[key] = value;
  }

  @override
  Future<void> command(List<String> args) async {
    commands.add(args);
    if (args.first == 'audio-add') {
      external = args[1];
      onAudioAdd?.call();
    }
    if (args.first == 'audio-remove') external = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform previous;
  late File original;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('movie-audio');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(directory);
    original = await File('${directory.path}/original.wav').writeAsBytes([1, 2, 3, 4]);
  });
  tearDown(() async {
    PathProviderPlatform.instance = previous;
    await directory.delete(recursive: true);
  });
  test('commentary restores settings and removal preserves the user file', () async {
    final player = _Player();
    final audio = MovieAudioAttachment(player, 'cut');
    await audio.attach(original, 'Voice.wav', true, () => true);
    final owned = audio.path!;
    expect(owned, isNot(original.path));
    expect(player.properties['audio-spdif'], '');
    expect(player.properties['lavfi-complex'], contains('amix=inputs=2'));
    expect(player.seeks.last, const Duration(seconds: 2));
    audio.delayMs = -1000;
    audio.voiceGain = .4;
    await audio.apply(() => true);
    await audio.persist();
    expect(player.external, startsWith('edl://'));
    expect(player.properties['lavfi-complex'], contains('volume=0.400'));
    final reopened = MovieAudioAttachment(_Player(), 'cut');
    await reopened.read();
    expect(reopened.delayMs, -1000);
    expect(reopened.voiceGain, .4);
    expect(reopened.path, owned);
    await audio.forget();
    expect(player.properties['aid'], '1');
    expect(player.properties['audio-delay'], '0.2');
    expect(player.properties['audio-spdif'], 'ac3,dts');
    expect(player.external, isNull);
    expect(await File(owned).exists(), isFalse);
    expect(await original.readAsBytes(), [1, 2, 3, 4]);
  });
  test('failed mix restores the original soundtrack and does not persist a broken attachment', () async {
    final player = _Player()..rejectMix = true;
    final audio = MovieAudioAttachment(player, 'cut');
    await expectLater(audio.attach(original, 'Voice.wav', true, () => true), throwsStateError);
    expect(audio.path, isNull);
    expect(player.external, isNull);
    expect(player.properties['audio-spdif'], 'ac3,dts');
    expect((await SharedPreferences.getInstance()).getString('cut'), isNull);
    expect(await original.exists(), isTrue);
  });
  test('an abandoned open does not seek or resume its replacement', () async {
    final player = _Player();
    var current = true;
    player.onAudioAdd = () => current = false;
    final audio = MovieAudioAttachment(player, 'cut');
    await audio.attach(original, 'Voice.wav', true, () => current);
    expect(player.seeks, isEmpty);
    expect(player.plays, 0);
    expect(audio.path, isNull);
    expect((await SharedPreferences.getInstance()).getString('cut'), isNull);
  });
  test('corrupt optional preferences do not break movie playback', () async {
    for (final raw in ['{bad', '[]', '{"asset":"../private.wav"}', '{"asset":12}']) {
      await (await SharedPreferences.getInstance()).setString('cut', raw);
      final audio = MovieAudioAttachment(_Player(), 'cut');
      await audio.read();
      expect(audio.path, isNull);
    }
  });
}
