import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/original_dialogue.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/track_selection_service.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('direct files honor an embedded original disposition while manual and negotiated picks win', () async {
    resetSharedPreferencesForTest();
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.preferOriginalDialogue, true);
    final catalog = MediaSourceInfo(
      videoUrl: 'file:///movie.mkv',
      chapters: [],
      subtitleTracks: [],
      audioTracks: [
        MediaAudioTrack(id: 10, index: 1, languageCode: 'eng', selected: true),
        MediaAudioTrack(id: 20, index: 2, languageCode: 'kor', selected: false),
      ],
    );
    const dub = AudioTrack(id: '1', ffIndex: 1, language: 'eng', isDefault: true);
    const original = AudioTrack(id: '2', ffIndex: 2, language: 'kor', originalDialogue: true);
    const tracks = [dub, original];
    TrackSelectionService service([MediaSourceInfo? info]) =>
        TrackSelectionService(metadata: testMediaItem(), plexMediaInfo: info);
    expect(service().selectAudioTrack(tracks, null)?.track, original);
    expect(service(catalog).selectAudioTrack(tracks, null)?.track, original);
    expect(service(catalog).selectAudioTrack(tracks, dub)?.track, dub);
    expect(service(catalog.selectAudio(10)).selectAudioTrack(tracks, null)?.track, dub);
    expect(service().selectAudioTrack([dub, original.copyWith(title: 'Audio Description')], null)?.track, dub);
    await settings.write(SettingsService.preferOriginalDialogue, false);
    expect(service(catalog).selectAudioTrack(tracks, null)?.track, dub);
  });
  MediaAudioTrack row(
    int id,
    String code, {
    String? title,
    bool original = false,
    bool dub = false,
    bool described = false,
  }) => MediaAudioTrack(
    id: id,
    languageCode: code,
    title: title,
    selected: false,
    original: original,
    dubbed: dub,
    described: described,
  );
  test('exact flags outrank language; dubs, AD and commentary cannot become the main dialogue', () {
    final tracks = [
      row(1, 'eng', dub: true),
      row(2, 'fra', title: 'Director commentary', original: true),
      row(3, 'fre', described: true, original: true),
      row(4, 'fra', original: true),
    ];
    expect(originalDialogue(tracks, language: 'en')?.id, 4);
    expect(originalDialogue([row(1, 'eng'), row(2, 'fra')], language: 'fr')?.id, 2);
    expect(originalDialogue([row(1, 'eng'), row(2, 'fra'), row(3, 'fre')], language: 'fr'), isNull);
    expect(originalDialogue([row(1, 'eng'), row(2, 'kor')]), isNull);
  });
}
