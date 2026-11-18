import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'source_models.dart';

class LocalFileRelink {
  const LocalFileRelink(this.id, this.path, this.oldRevision, this.newRevision, {this.verified = false});
  final String id, path, oldRevision, newRevision;
  final bool verified;
  Map<String, String> toJson() => {'id': id, 'path': path, 'oldRevision': oldRevision, 'newRevision': newRevision};

  static List<LocalFileRelink> decode(String? value) {
    if (value == null) return [];
    try {
      return [
        for (final row in sourceList(jsonDecode(value)))
          LocalFileRelink(
            row['id'] as String,
            row['path'] as String,
            row['oldRevision'] as String,
            row['newRevision'] as String,
          ),
      ];
    } on FormatException {
      return [];
    } on TypeError {
      return [];
    }
  }

  static Future<List<LocalFileRelink>> preview({
    required String root,
    required String oldFolder,
    required String newFolder,
    required Iterable<SourceEntry> entries,
    required Future<File?> Function(PublicationFile) offlineCopy,
  }) async {
    final base = await Directory(root).resolveSymbolicLinks();
    final target = await Directory(newFolder).resolveSymbolicLinks();
    if (target != base && !p.isWithin(base, target)) throw const SourceException(SourceFailure.permission);
    final rows = <LocalFileRelink>[];
    for (final entry in entries) {
      final file = entry.files.singleOrNull;
      if (file == null || file.id != entry.id || file.revision == null || !p.isWithin(oldFolder, entry.id)) continue;
      final old = p.join(base, entry.id);
      if (await FileSystemEntity.type(old, followLinks: false) != FileSystemEntityType.notFound) continue;
      final candidate = File(p.join(target, p.relative(entry.id, from: oldFolder)));
      if (await FileSystemEntity.type(candidate.path, followLinks: false) != FileSystemEntityType.file) continue;
      final physical = await candidate.resolveSymbolicLinks();
      if (!p.isWithin(target, physical)) continue;
      final stat = await candidate.stat();
      if (stat.size != file.size) continue;
      final cached = await offlineCopy(file);
      if (cached != null && await sha256.bind(cached.openRead()).first != await sha256.bind(candidate.openRead()).first)
        continue;
      rows.add(
        LocalFileRelink(
          file.id,
          p.relative(physical, from: base),
          file.revision!,
          '${stat.modified.microsecondsSinceEpoch}:${stat.size}',
          verified: cached != null,
        ),
      );
    }
    return rows;
  }
}
