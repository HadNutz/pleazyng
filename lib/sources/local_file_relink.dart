import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'source_models.dart';

class LocalFileRelink {
  const LocalFileRelink(
    this.id,
    this.path,
    this.oldRevision,
    this.newRevision, {
    this.verified = false,
    this.mountRoot,
    this.progressEdition,
  });
  final String id, path, oldRevision, newRevision;
  final bool verified;
  final String? mountRoot, progressEdition;
  static String mountId(String root) => '@moved-${sourceDigest(root)}';
  String get replacementId => '@replacement-${sourceDigest(id)}';
  static String physicalPath(String root, String catalogPath, String? mount) {
    if (mount == null) return p.join(root, catalogPath);
    final prefix = mountId(mount);
    if (catalogPath == prefix) return mount;
    if (!p.isWithin(prefix, catalogPath)) throw const SourceException(SourceFailure.permission);
    return p.join(mount, p.relative(catalogPath, from: prefix));
  }

  Map<String, Object> toJson() => {
    'id': id,
    'path': path,
    'oldRevision': oldRevision,
    'newRevision': newRevision,
    'verified': verified,
    if (mountRoot != null) 'mountRoot': mountRoot!,
    if (progressEdition != null) 'progressEdition': progressEdition!,
  };

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
            verified: row['verified'] == true,
            mountRoot: row['mountRoot'] as String?,
            progressEdition: row['progressEdition'] as String?,
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
    List<LocalFileRelink> previous = const [],
  }) async {
    if (p.isAbsolute(oldFolder) || p.normalize(oldFolder).startsWith('..')) {
      throw const SourceException(SourceFailure.permission);
    }
    String base;
    try {
      base = await Directory(root).resolveSymbolicLinks();
    } on FileSystemException {
      base = p.normalize(p.absolute(root));
    }
    final target = await Directory(newFolder).resolveSymbolicLinks();
    final outsideRoot = !p.equals(base, target) && !p.isWithin(base, target);
    final destinationRoot = outsideRoot ? target : base;
    // Moving a subfolder across volumes keeps the other shelves under the original root.
    final mount = outsideRoot && oldFolder != '.' ? target : null;
    final byId = {for (final row in previous) row.id: row};
    final rows = <LocalFileRelink>[];
    for (final entry in entries) {
      final file = entry.files.singleOrNull;
      if (file == null || file.id != entry.id || file.revision == null) continue;
      final last = byId[entry.id];
      final catalogPath = last?.path ?? entry.id;
      if (!p.isWithin(oldFolder, catalogPath)) continue;
      final old = physicalPath(base, catalogPath, last?.mountRoot);
      if (await FileSystemEntity.type(old, followLinks: false) != FileSystemEntityType.notFound) continue;
      final candidate = File(p.join(target, p.relative(catalogPath, from: oldFolder)));
      if (await FileSystemEntity.type(candidate.path, followLinks: false) != FileSystemEntityType.file) continue;
      final physical = await candidate.resolveSymbolicLinks();
      if (!p.isWithin(target, physical)) continue;
      final stat = await candidate.stat();
      if (stat.size != file.size) continue;
      final cached = await offlineCopy(file);
      if (cached != null &&
          await sha256.bind(cached.openRead()).first != await sha256.bind(candidate.openRead()).first) {
        continue;
      }
      rows.add(
        LocalFileRelink(
          file.id,
          p.join(mount == null ? '' : mountId(mount), p.relative(physical, from: destinationRoot)),
          file.revision!,
          '${stat.modified.microsecondsSinceEpoch}:${stat.size}',
          verified: cached != null,
          mountRoot: mount,
          progressEdition: file.progressFingerprint,
        ),
      );
    }
    return rows;
  }
}
