// Run with Dart and FFmpeg on PATH. Fault-inject the production finalizer,
// then decode every surviving capture rather than accepting a file's existence.
import 'dart:io';

import 'package:plezy/iptv/iptv_manual_capture.dart';

Future<void> ffmpeg(List<String> arguments) async {
  final result = await Process.run('ffmpeg', ['-nostdin', '-v', 'error', ...arguments]);
  if (result.exitCode != 0) throw StateError('FFmpeg failed: ${result.stderr}');
}

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('pleazyng-capture-recovery-');
  try {
    final source = File('${root.path}/source.ts');
    await ffmpeg([
      '-f',
      'lavfi',
      '-i',
      'testsrc2=s=160x90:r=15',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440',
      '-t',
      '2',
      '-c:v',
      'mpeg2video',
      '-c:a',
      'mp2',
      '-f',
      'mpegts',
      source.path,
    ]);
    final original = await source.readAsBytes();
    for (final mode in ['normal', 'close failure', 'collision', 'journal failure']) {
      final folder = await Directory('${root.path}/$mode').create();
      final partial = await source.copy('${folder.path}/.partial.ts');
      final target = File('${folder.path}/recording.ts');
      if (mode == 'collision') await target.writeAsString('unrelated recording');
      String? journaled;
      final saved = await finishManualCapture(
        partial: partial,
        target: target,
        closeWriter: () async {
          if (mode == 'close failure') throw StateError('Injected writer close failure');
        },
        journal: (path) async {
          if (mode == 'journal failure' && path == target.path) throw StateError('Injected database failure');
          journaled = path;
        },
      );
      final bytes = await saved.file.readAsBytes();
      if (saved.complete != (mode == 'normal') ||
          journaled != saved.file.path ||
          saved.size != original.length ||
          bytes.length != original.length) {
        throw StateError('$mode: invalid completion, journal or size');
      }
      for (var index = 0; index < original.length; index++) {
        if (bytes[index] != original[index]) throw StateError('$mode: capture changed at byte $index');
      }
      if (mode == 'collision' && await target.readAsString() != 'unrelated recording') {
        throw StateError('Destination collision overwrote unrelated media');
      }
      await ffmpeg(['-xerror', '-i', saved.file.path, '-map', '0:v', '-map', '0:a', '-f', 'null', '-']);
      stdout.writeln('$mode: ${saved.size} own bytes preserved; video and audio decoded');
    }
  } finally {
    await root.delete(recursive: true);
  }
}
