import 'dart:io';
import 'dart:async';
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
  test('buffered capture starts while its async dump remains open and flushes on stop', () async {
    final folder = await Directory.systemTemp.createTemp('iptv-buffer');
    addTearDown(() => folder.delete(recursive: true));
    final output = File('${folder.path}/capture.ts');
    final dumping = Completer<void>();
    final requests = <List<String>>[];
    final capture = BufferedIptvCapture((args) async {
      requests.add(args);
      if (args.last.isEmpty) {
        await output.writeAsBytes([4, 5, 6], mode: FileMode.append);
        dumping.complete();
      } else {
        await output.writeAsBytes([1, 2, 3]);
        await dumping.future;
      }
    });
    await capture.start(output, 12.345);
    expect(dumping.isCompleted, isFalse);
    expect(requests.single, ['dump-cache', '12.345', 'no', output.path]);
    await capture.stop();
    expect(await output.readAsBytes(), [1, 2, 3, 4, 5, 6]);
  });
  test('buffered capture reports a rejected command instead of claiming success', () async {
    final folder = await Directory.systemTemp.createTemp('iptv-buffer-error');
    addTearDown(() => folder.delete(recursive: true));
    final capture = BufferedIptvCapture((_) async => throw StateError('not supported'));
    await expectLater(capture.start(File('${folder.path}/capture.ts'), 0), throwsStateError);
  });
}
