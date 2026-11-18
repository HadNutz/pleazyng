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
    await Future.wait([capture.stop(), capture.stop()]);
    expect(requests.where((args) => args.last.isEmpty), hasLength(1));
    expect(await output.readAsBytes(), [1, 2, 3, 4, 5, 6]);
  });
  test('an empty file left by a failing muxer never announces a recording', () async {
    final folder = await Directory.systemTemp.createTemp('iptv-empty-buffer');
    addTearDown(() => folder.delete(recursive: true));
    final output = await File('${folder.path}/capture.ts').create();
    final failure = Completer<void>();
    final capture = BufferedIptvCapture((_) => failure.future);
    final startup = expectLater(capture.start(output, 0), throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    failure.completeError(StateError('muxer rejected the stream'));
    await startup;
    expect(await output.length(), 0);
  });
  test('buffered capture reports a rejected command instead of claiming success', () async {
    final folder = await Directory.systemTemp.createTemp('iptv-buffer-error');
    addTearDown(() => folder.delete(recursive: true));
    final capture = BufferedIptvCapture((_) async => throw StateError('not supported'));
    await expectLater(capture.start(File('${folder.path}/capture.ts'), 0), throwsStateError);
  });
}
