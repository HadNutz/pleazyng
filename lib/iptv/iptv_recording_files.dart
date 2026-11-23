import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> publishRecordingFile(File file, Future<void> Function(File) write) async {
  final staging = await file.parent.createTemp('.recording-');
  try {
    final temporary = File(p.join(staging.path, 'payload'));
    await write(temporary);
    await temporary.rename(file.path);
  } finally {
    await staging.delete(recursive: true);
  }
}

bool ownsRecordingDirectory(File manifest, Directory folder, String recordingId) {
  final name = p.basename(manifest.path), stem = p.basenameWithoutExtension(name);
  return {'.$recordingId.media', '$name.media', '$stem.media', '.$stem.media'}.contains(p.basename(folder.path));
}

Future<String?> readRecordingPlaylist(File playlist) async {
  const limit = 16 * 1024 * 1024;
  final type = await FileSystemEntity.type(playlist.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return null;
  if (type != FileSystemEntityType.file) throw const FormatException('Invalid HLS playlist');
  final input = await playlist.open();
  try {
    final size = await input.length();
    if (size > limit) throw const FormatException('Invalid HLS playlist size');
    final bytes = await input.read(size);
    if (bytes.length != size || await input.readByte() != -1) throw const FormatException('HLS playlist changed');
    return utf8.decode(bytes);
  } finally {
    await input.close();
  }
}
