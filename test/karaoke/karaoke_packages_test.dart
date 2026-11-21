import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/karaoke/karaoke_packages.dart';
import 'package:plezy/karaoke/karaoke_store.dart';

class _Store extends KaraokeStore {
  _Store(this.root) : super('test');
  final Directory root;
  @override
  Future<Directory> get directory async => root;
}

void main() {
  test('pairs MIDI notes with explicit sidecar lyrics, including when the backing has lyrics', () async {
    final root = await Directory.systemTemp.createTemp('paired-karaoke');
    addTearDown(() => root.delete(recursive: true));
    final source = await Directory('${root.path}/sources').create();
    final midi = File('${source.path}/song.mid');
    final events = [0, 0xff, 0x05, 3, ...'old'.codeUnits, 0, 0x90, 60, 64, 0x60, 0x80, 60, 0, 0, 0xff, 0x2f, 0];
    await midi.writeAsBytes([
      ...'MThd'.codeUnits,
      0,
      0,
      0,
      6,
      0,
      0,
      0,
      1,
      0,
      96,
      ...'MTrk'.codeUnits,
      0,
      0,
      0,
      events.length,
      ...events,
    ]);
    final words = await File('${source.path}/song.lrc').writeAsString('[00:00.00]Sing along\n[00:01.00]Second line');
    final result = await KaraokePackages(_Store(root)).importFiles([midi.path, words.path]);
    expect(result.track.notes, hasLength(1));
    expect(result.track.lyrics.lines.map((line) => line.text), ['Sing along', 'Second line']);
    expect(result.track.assets.map((asset) => asset.path), unorderedEquals(['song.mid', 'song.lrc']));
  });
}
