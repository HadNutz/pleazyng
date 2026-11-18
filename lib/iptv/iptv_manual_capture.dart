import 'dart:io';

/// Only [partial] belongs to this capture. A pre-existing destination can never
/// be used to infer success or the number of bytes that survived.
Future<({File file, int size, bool complete})> finishManualCapture({
  required File partial,
  required File target,
  required Future<void> Function() closeWriter,
  required Future<void> Function(String) journal,
}) async {
  var reserved = false;
  try {
    await closeWriter();
    final size = await partial.length();
    if (size == 0) throw const FileSystemException('Empty recording');
    await target.create(exclusive: true);
    reserved = true;
    // Restart recovery also checks the exact app-owned partial if the process
    // dies between journaling the destination and publishing the bytes.
    await journal(target.path);
    await partial.rename(target.path);
    return (file: target, size: size, complete: true);
  } catch (_) {
    if (reserved && await target.exists() && await target.length() == 0) await target.delete();
    final size = await partial.exists() ? await partial.length() : 0;
    await journal(partial.path);
    if (size == 0 && await partial.exists()) await partial.delete();
    return (file: partial, size: size, complete: false);
  }
}
