import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/original_dialogue.dart';
import 'package:plezy/media/media_source_info.dart';

void main() {
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
