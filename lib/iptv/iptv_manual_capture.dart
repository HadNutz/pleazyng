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

/// One demuxer owns both the cached packets and the live continuation. mpv
/// completes the asynchronous command on stop; some platform bridges instead
/// acknowledge submission immediately. The first written bytes confirm startup.
class BufferedIptvCapture {
  BufferedIptvCapture(this.command);
  final Future<void> Function(List<String>) command;
  Object? _error;
  Future<void>? _dump;
  Future<void>? _stopping;

  Future<void> start(File output, double offset) async {
    _dump = command(['dump-cache', offset.toStringAsFixed(3), 'no', output.path]).catchError((Object error) {
      _error = error;
    });
    final clock = Stopwatch()..start();
    while (true) {
      final stat = await output.stat();
      if (_error != null) throw StateError('Buffered recording failed: $_error');
      if (stat.type == FileSystemEntityType.file && stat.size > 0) return;
      if (clock.elapsed > const Duration(seconds: 5)) {
        await stop();
        throw const FileSystemException('Buffered recording did not start');
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    const timeout = Duration(seconds: 5);
    await command(['dump-cache', 'no', 'no', '']).timeout(timeout);
    await _dump?.timeout(timeout);
    if (_error != null) throw StateError('Buffered recording interrupted: $_error');
  }
}
