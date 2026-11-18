import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/iptv/iptv_manual_capture.dart';

void main() {
  for (final mode in ['normal', 'close failure', 'collision', 'journal failure']) {
    test('manual capture preserves its own bytes on $mode', () async {
      final folder = await Directory.systemTemp.createTemp('iptv-capture');
      addTearDown(() => folder.delete(recursive: true));
      final partial = File('${folder.path}/.partial.ts');
      final target = File('${folder.path}/show.ts');
      final bytes = [0x47, 0x40, 0, 0x10, ...List.filled(184, 0xff)];
      await partial.writeAsBytes(bytes);
      if (mode == 'collision') await target.writeAsString('unrelated');
      String? journaled;
      final result = await finishManualCapture(
        partial: partial,
        target: target,
        closeWriter: () async {
          if (mode == 'close failure') throw StateError('closed');
        },
        journal: (path) async {
          if (mode == 'journal failure' && path == target.path) throw StateError('database busy');
          journaled = path;
        },
      );
      expect(result.complete, mode == 'normal');
      expect(await File(journaled!).readAsBytes(), bytes);
      expect(result.size, bytes.length);
      if (mode == 'collision') expect(await target.readAsString(), 'unrelated');
    });
  }
}
