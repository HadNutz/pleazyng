import 'dart:io';

import 'package:background_downloader/src/desktop/storage_space.dart';
import 'package:background_downloader/src/exceptions.dart';
import 'package:flutter_test/flutter_test.dart';

const _mib = 1024 * 1024;

void main() {
  group('important-usage capacity', () {
    const total = 100 * 1024 * _mib;
    const floor = 1024 * _mib;
    const request = 100 * _mib;

    test('plain refusal defers to purgeable-inclusive capacity', () {
      final guard = StorageSpaceGuard(
        '/target',
        -1,
        capacity: (_) => (available: floor + 10 * _mib, total: total),
        importantCapacity: (_) => 5 * floor,
      );
      guard.check(request);
    });

    test('plain capacity that fits never queries important usage', () {
      var queries = 0;
      final guard = StorageSpaceGuard(
        '/target',
        -1,
        capacity: (_) => (available: floor + request, total: total),
        importantCapacity: (_) {
          queries++;
          return 5 * floor;
        },
      );
      guard.check(request);
      guard.check(request);
      expect(queries, 0);
    });

    test('refusal by both reports the figures', () {
      final guard = StorageSpaceGuard(
        '/target',
        -1,
        capacity: (_) => (available: floor + 10 * _mib, total: total),
        importantCapacity: (_) => floor + 20 * _mib,
      );
      expect(
        () => guard.check(request),
        throwsA(
          isA<TaskFileSystemException>()
              .having(isDownloadStorageFailure, 'storage failure', isTrue)
              .having(
                (e) => e.description,
                'description',
                allOf(
                  startsWith('Insufficient space to store download: '),
                  contains('needs $request bytes'),
                  contains('reserve of $floor bytes'),
                  contains('${floor + 10 * _mib} bytes free'),
                  contains('${floor + 20 * _mib} for important usage'),
                ),
              ),
        ),
      );
    });

    test('unavailable important usage leaves the plain refusal', () {
      for (final important in <int? Function(String)>[
        (_) => null,
        (_) => 0,
        (_) => throw const FileSystemException('query failed'),
      ]) {
        final guard = StorageSpaceGuard(
          '/target',
          -1,
          capacity: (_) => (available: floor + 10 * _mib, total: total),
          importantCapacity: important,
        );
        expect(
          () => guard.check(request),
          throwsA(
            predicate(
              (TaskException e) => isDownloadStorageFailure(e) && e.description.contains('unknown for important usage'),
            ),
          ),
        );
      }
    });

    test('a sample serves its age, charged with bytes written since', () {
      var now = DateTime(2026);
      var available = floor + 10 * _mib;
      var important = floor + 2 * request;
      var queries = 0;
      final guard = StorageSpaceGuard(
        '/target',
        -1,
        capacity: (_) => (available: available, total: total),
        importantCapacity: (_) {
          queries++;
          return important;
        },
        clock: () => now,
      );
      guard.check(request);
      expect(queries, 1);
      // Written since the sample: the estimate still fits.
      available -= 50 * _mib;
      guard.check(request);
      expect(queries, 1);
      // The estimate would refuse; a fresh sample decides, and the system
      // has since purged more.
      available -= 60 * _mib;
      important = floor + 3 * request;
      guard.check(request);
      expect(queries, 2);
      // A refused estimate re-samples, and a refusing fresh sample is final.
      available -= 250 * _mib;
      important = floor + request - 1;
      expect(() => guard.check(request), throwsA(predicate(isDownloadStorageFailure)));
      expect(queries, 3);
      // Space purged after the refusal counts at the next check.
      important = 5 * floor;
      guard.check(request);
      expect(queries, 4);
      // An expired sample is replaced even though its estimate fits.
      now = now.add(StorageSpaceGuard.importantSampleAge);
      guard.check(request);
      expect(queries, 5);
    });

    test('macOS reports it for the containing volume', () {
      final path = '${Directory.systemTemp.path}/bd_missing/child';
      final available = desktopVolumeCapacity(path).available;
      final important = desktopImportantCapacity(path);
      if (!Platform.isMacOS) {
        expect(important, isNull);
        return;
      }
      expect(important, greaterThan(0));
      // Purgeable space comes on top; allow for other writers between queries.
      expect(important, greaterThan(available - 1024 * _mib));
    });
  });
}
