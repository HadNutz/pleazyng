part of 'orphan_download_cleanup_service.dart';

/// The checkpoint holds the last inspected name in each open directory.
/// Candidate chunks are flushed before the cursor that references them.
extension ResumableOrphanScan on OrphanDownloadCleanupService {
  Future<OrphanDownloadScan> scanWithCheckpoint(
    Directory root,
    Directory cache, {
    required Set<String> protectedTags,
    void Function(int)? onProgress,
    bool Function()? cancelled,
  }) async {
    final canonical = path.normalize(await root.resolveSymbolicLinks());
    if (await FileSystemEntity.type(root.path, followLinks: false) != FileSystemEntityType.directory) {
      return OrphanDownloadScan(
        rootPath: canonical,
        files: [],
        failure: OrphanDownloadScanFailure.unsafeRoot,
        scannedEntries: 0,
      );
    }
    final directory = Directory(path.join(cache.path, sha256.convert(utf8.encode(canonical)).toString()));
    await directory.create(recursive: true);
    final checkpoint = File(path.join(directory.path, 'cursor.json'));
    final stack = [
      <String, String>{'path': '', 'after': ''},
    ];
    final state = _ScanState(rootPath: canonical, protectedTags: protectedTags, maxEntries: maxEntries);
    var chunks = 0, saved = 0;
    if (await checkpoint.exists()) {
      try {
        final data = jsonDecode(await checkpoint.readAsString()) as Map;
        if (data['root'] == canonical && data['version'] == 1) {
          final frames = (data['stack'] as List).map((e) => Map<String, String>.from(e as Map)).toList();
          if (frames.length > 6 ||
              frames.any((f) => path.isAbsolute(f['path']!) || path.split(f['path']!).contains('..'))) {
            throw const FormatException('Invalid scan cursor');
          }
          chunks = data['chunks'] as int;
          state.scannedEntries = data['entries'] as int;
          stack
            ..clear()
            ..addAll(frames);
        }
      } catch (_) {
        if (await checkpoint.exists()) await checkpoint.delete();
        chunks = 0;
        state.scannedEntries = 0;
        stack
          ..clear()
          ..add({'path': '', 'after': ''});
      }
    }
    Future<void> write(File file, Object data) async {
      final pending = File('${file.path}.pending');
      await pending.writeAsString(jsonEncode(data), flush: true);
      await pending.rename(file.path);
    }

    Future<void> save() async {
      if (state.files.isNotEmpty) {
        await write(File(path.join(directory.path, '$chunks.json')), [
          for (final f in state.files) [f.relativePath, f.itemTag, f.sizeBytes, f.modified.microsecondsSinceEpoch],
        ]);
        chunks++;
        state.files.clear();
      }
      await write(checkpoint, {
        'version': 1,
        'root': canonical,
        'chunks': chunks,
        'entries': state.scannedEntries,
        'stack': stack,
      });
      saved = state.scannedEntries;
      onProgress?.call(saved);
    }

    final iterators = <String, Iterator<String>>{};
    final budget = maxEntries.clamp(1, 1024);
    while (stack.isNotEmpty) {
      if (cancelled?.call() == true) {
        await save();
        return OrphanDownloadScan(
          rootPath: canonical,
          files: [],
          failure: OrphanDownloadScanFailure.cancelled,
          scannedEntries: saved,
        );
      }
      final frame = stack.last, rel = frame['path']!;
      var iterator = iterators[rel];
      if (iterator == null) {
        final folder = Directory(rel.isEmpty ? canonical : path.join(canonical, rel));
        final names = <String>[];
        if (await _isRealDirectory(folder) && (rel.isEmpty || await state.isWithinRoot(folder.path))) {
          if (rel.isEmpty) {
            names.addAll(['Movies', 'Music', 'TV Shows'].where((name) => name.compareTo(frame['after']!) > 0));
          } else {
            await for (final e in folder.list(followLinks: false)) {
              if (cancelled?.call() == true) break;
              final name = path.basename(e.path);
              if (name.compareTo(frame['after']!) > 0) names.add(name);
            }
          }
        }
        names.sort();
        iterator = iterators[rel] = names.iterator;
        if (cancelled?.call() == true) continue;
      }
      if (!iterator.moveNext()) {
        iterators.remove(rel);
        stack.removeLast();
        continue;
      }
      final name = iterator.current;
      final relative = rel.isEmpty ? name : path.join(rel, name);
      final segments = path.split(relative), full = path.join(canonical, relative);
      final type = await FileSystemEntity.type(full, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        final descend = switch (segments.first) {
          'Movies' =>
            segments.length <= 2 ||
                segments.length == 3 && OrphanDownloadCleanupService._subtitleDirectoryTag.hasMatch(name),
          'TV Shows' =>
            segments.length <= 2 ||
                segments.length == 3 && OrphanDownloadCleanupService._seasonDirectory.hasMatch(name) ||
                segments.length == 4 && OrphanDownloadCleanupService._subtitleDirectoryTag.hasMatch(name),
          'Music' => segments.length <= 3,
          _ => false,
        };
        if (descend && await state.isWithinRoot(full)) stack.add({'path': relative, 'after': ''});
      } else if (type == FileSystemEntityType.file && segments.length >= 3) {
        final tag =
            _extractTag(path.basenameWithoutExtension(name)) ??
            OrphanDownloadCleanupService._subtitleDirectoryTag.firstMatch(segments[segments.length - 2])?.group(1);
        if (tag != null && !protectedTags.contains(tag)) {
          final file = OrphanDownloadFile(
            relativePath: relative,
            itemTag: tag,
            sizeBytes: 0,
            modified: DateTime.fromMillisecondsSinceEpoch(0),
          );
          if (_isRecognizedCandidate(file, segments) && await state.isWithinRoot(full))
            await state.addCandidate(full, tag);
        }
      }
      frame['after'] = name;
      state.scannedEntries++;
      if (state.scannedEntries - saved >= budget) {
        await save();
        await Future<void>.delayed(Duration.zero);
      }
    }
    await save();
    final files = <OrphanDownloadFile>[];
    try {
      for (var n = 0; n < chunks; n++) {
        for (final r in jsonDecode(await File(path.join(directory.path, '$n.json')).readAsString()) as List) {
          if (!protectedTags.contains(r[1]))
            files.add(
              OrphanDownloadFile(
                relativePath: r[0],
                itemTag: r[1],
                sizeBytes: r[2],
                modified: DateTime.fromMicrosecondsSinceEpoch(r[3]),
              ),
            );
        }
      }
    } on Object {
      // A damaged cache must not strand every later review on the same cursor.
      await directory.delete(recursive: true);
      rethrow;
    }
    files.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    await directory.delete(recursive: true);
    return OrphanDownloadScan(rootPath: canonical, files: files, failure: null, scannedEntries: saved);
  }
}
