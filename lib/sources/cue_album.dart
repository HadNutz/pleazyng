import 'dart:convert';
import 'source_models.dart';

/// Offsets are kept in CD frames until the playback boundary.
class _CueTrack {
  _CueTrack(this.number, this.file, this.artist);
  final int number;
  final String file;
  String title = '', artist;
  int? start;
}

Future<List<SourceEntry>> cueAlbumEntries({
  required List<int> bytes,
  required String source,
  required String parent,
  required String sheet,
  required Future<PublicationFile?> Function(String) lookup,
}) async {
  if (bytes.length > 1024 * 1024) return [];
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    text = latin1.decode(bytes);
  }
  text = text.replaceFirst('\uFEFF', '');
  final tracks = <_CueTrack>[];
  String? filename;
  var album = '', artist = '';
  _CueTrack? track;
  for (final line in const LineSplitter().convert(text)) {
    final match = RegExp(r'^\s*(FILE|TRACK|TITLE|PERFORMER|INDEX)\s+(.+?)\s*$', caseSensitive: false).firstMatch(line);
    if (match == null) continue;
    final value = match[2]!, unquoted = value.replaceFirst(RegExp('^"'), '').replaceFirst(RegExp('"\$'), '');
    switch (match[1]!.toUpperCase()) {
      case 'FILE':
        final file = RegExp(r'^(?:"([^"]+)"|(.+))\s+\w+$').firstMatch(value);
        filename = file?[1] ?? file?[2];
        if (filename == null || filename.contains(RegExp(r'[/\\:\x00]')) || filename.startsWith('.')) return [];
        track = null;
      case 'TRACK':
        final row = RegExp(r'^(\d{1,3})\s+AUDIO$', caseSensitive: false).firstMatch(value);
        if (row == null || filename == null || tracks.length >= 100) return [];
        final n = int.parse(row[1]!);
        if (n < 1 || tracks.any((t) => t.number == n)) return [];
        track = _CueTrack(n, filename, artist);
        tracks.add(track);
      case 'TITLE':
        if (track == null) {
          album = unquoted;
        } else {
          track.title = unquoted;
        }
      case 'PERFORMER':
        if (track == null) {
          artist = unquoted;
        } else {
          track.artist = unquoted;
        }
      case 'INDEX':
        final idx = RegExp(r'^01\s+(\d+):(\d{2}):(\d{2})$').firstMatch(value);
        if (idx != null && track != null) {
          final seconds = int.parse(idx[2]!), frames = int.parse(idx[3]!);
          if (seconds >= 60 || frames >= 75 || track.start != null) return [];
          final minutes = int.tryParse(idx[1]!);
          if (minutes == null || minutes > 1000000) return [];
          track.start = (minutes * 60 + seconds) * 75 + frames;
        }
    }
  }
  if (tracks.isEmpty || tracks.any((t) => t.start == null)) return [];
  final media = <String, PublicationFile>{};
  for (final name in tracks.map((t) => t.file).toSet()) {
    final file = await lookup(name);
    if (file == null || file.kind != SourceItemKind.music) return [];
    media[name] = file;
  }
  final name = album.isEmpty ? sheet.split('/').last.replaceFirst(RegExp(r'\.cue$', caseSensitive: false), '') : album;
  final entries = <SourceEntry>[], chapters = <BookChapter>[];
  for (var i = 0; i < tracks.length; i++) {
    final t = tracks[i], start = t.start!, next = tracks.elementAtOrNull(i + 1);
    final end = next?.file == t.file ? next?.start : null;
    if (end != null && end <= start) return [];
    final file = media[t.file]!, title = t.title.isEmpty ? t.number.toString().padLeft(2, '0') : t.title;
    final slice = PublicationFile.fromJson({
      ...file.toJson(),
      'cueStart': start,
      'cueEnd': ?end,
      'durationMs': end == null ? null : ((end - start) * 1000 / 75).round(),
    });
    entries.add(
      SourceEntry(
        sourceId: source,
        id: '$sheet#track-${t.number}',
        parentId: parent,
        title: title,
        author: t.artist,
        series: name,
        seriesOrder: t.number.toDouble(),
        kind: SourceItemKind.music,
        files: [slice],
      ),
    );
    if (media.length == 1) {
      chapters.add(
        BookChapter(
          title: title,
          startMs: (start * 1000 / 75).round(),
          endMs: end == null ? 0 : (end * 1000 / 75).round(),
        ),
      );
    }
  }
  return [
    SourceEntry(
      sourceId: source,
      id: sheet,
      parentId: parent,
      title: name,
      author: artist,
      kind: SourceItemKind.music,
      files: media.values.toList(),
      chapters: chapters,
    ),
    ...entries,
  ];
}

String cuePlaybackAddress(PublicationFile file, String address) {
  final start = file.cueStart;
  if (start == null) return address;
  final length = file.cueEnd == null ? '' : ',${((file.cueEnd! - start) / 75).toStringAsFixed(9)}';
  return 'edl://%${utf8.encode(address).length}%$address,${(start / 75).toStringAsFixed(9)}$length';
}
