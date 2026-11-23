import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/bounded_picked_file.dart';

void main() {
  test('picker streams stop at the first overflowing chunk with an understated size', () async {
    var chunks = 0;
    Stream<List<int>> input() async* {
      for (final chunk in [
        [1, 2],
        [3, 4],
        [5],
      ]) {
        chunks++;
        yield chunk;
      }
    }

    final picked = PlatformFile(name: 'import', size: 1, readStream: input());
    await expectLater(readBoundedPickedFile(picked, 3), throwsFormatException);
    expect(chunks, 2);
  });

  test('inline, filesystem and stream results enforce actual size and optional length matching', () async {
    final dir = await Directory.systemTemp.createTemp('bounded-picker-');
    addTearDown(() => dir.delete(recursive: true));
    final bytes = Uint8List.fromList([1, 2, 3]);
    final path = await File('${dir.path}/sample').writeAsBytes(bytes);
    for (final picked in [
      PlatformFile(name: 'inline', bytes: bytes, size: 1),
      PlatformFile(name: 'local', path: path.path, size: 1),
    ]) {
      expect(await readBoundedPickedFile(picked, 3), bytes);
      await expectLater(readBoundedPickedFile(picked, 2), throwsFormatException);
      await expectLater(readBoundedPickedFile(picked, 3, matchReportedSize: true), throwsFormatException);
    }
    final unknown = PlatformFile(name: 'provider', size: 0, readStream: Stream.value(bytes));
    expect(await readBoundedPickedFile(unknown, 3), bytes);
  });
}
