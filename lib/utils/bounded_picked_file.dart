import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Reads a picker result without trusting its reported size. Callers should
/// request a stream so the platform does not eagerly allocate the whole file.
Future<Uint8List> readBoundedPickedFile(
  PlatformFile file,
  int maxBytes, {
  Exception invalid = const FormatException('Invalid selected file size or contents.'),
  bool matchReportedSize = false,
  void Function()? checkCurrent,
}) async {
  checkCurrent?.call();
  if (file.size > maxBytes || (matchReportedSize && file.size <= 0)) throw invalid;
  final limit = matchReportedSize ? file.size : maxBytes;
  final inline = file.bytes;
  if (inline != null) {
    if (inline.isEmpty || inline.length > limit || (matchReportedSize && inline.length != file.size)) throw invalid;
    return Uint8List.fromList(inline);
  }

  final stream = file.readStream ?? (file.path == null ? null : File(file.path!).openRead());
  if (stream == null) throw invalid;
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    checkCurrent?.call();
    if (chunk.length > limit - bytes.length) throw invalid;
    bytes.add(chunk);
  }
  if (bytes.isEmpty || (matchReportedSize && bytes.length != file.size)) throw invalid;
  return bytes.takeBytes();
}
