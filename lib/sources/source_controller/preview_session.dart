part of '../source_controller.dart';

/// A bounded, temporary, cancel-on-close file used only by a sample preview.
/// It is intentionally separate from publication downloads and progress.
class SourcePreviewSession {
  SourcePreviewSession(this._adapter, this.file, {required this._check});

  static const int maxBytes = 128 * 1024 * 1024;
  final SourceAdapter _adapter;
  final PublicationFile file;
  final void Function() _check;
  final TransferCancellation _cancellation = TransferCancellation();
  Directory? _directory;
  Future<File>? _opening;
  bool _disposed = false;

  Future<File> open() => _opening ??= _open();

  void _requireCurrent() {
    if (_disposed) {
      throw const SourceException(SourceFailure.cancelled);
    }
    _cancellation.check();
    _check();
  }

  Future<File> _open() async {
    _requireCurrent();
    if (!file.previewableSample || (file.size != null && file.size! > maxBytes)) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final temp = await getTemporaryDirectory();
    _requireCurrent();
    _directory = await temp.createTemp('plezy-sample-');
    final extension = p.extension(file.name);
    final safeExtension = RegExp(r'^\.[a-zA-Z0-9]{1,8}$').hasMatch(extension) ? extension : '';
    final target = File(p.join(_directory!.path, 'preview$safeExtension'));
    Stream<List<int>> stream;
    int? expectedSize = file.size;

    try {
      final direct = await _adapter.openContent(file, offset: 0, length: maxBytes + 1);
      if (direct != null) {
        try {
          _requireCurrent();
        } on Object {
          await direct.stream.listen((_) {}).cancel();
          rethrow;
        }
        if (direct.offset != 0 || direct.size > maxBytes || direct.length != direct.size) {
          await direct.stream.listen((_) {}).cancel();
          throw const SourceException(SourceFailure.invalidData);
        }
        expectedSize = direct.size;
        stream = direct.stream;
      } else {
        _requireCurrent();
        final lease = await _adapter.resolve(file);
        _requireCurrent();
        if (expectedSize != null && lease.size != null && expectedSize != lease.size) {
          throw const SourceException(SourceFailure.invalidData);
        }
        expectedSize ??= lease.size;
        if (expectedSize != null && expectedSize > maxBytes) {
          throw const SourceException(SourceFailure.invalidData);
        }
        if (lease.uri.scheme == 'file') {
          final local = File.fromUri(lease.uri);
          final stat = await local.stat();
          _requireCurrent();
          if (stat.type != FileSystemEntityType.file || stat.size <= 0 || stat.size > maxBytes) {
            throw const SourceException(SourceFailure.invalidData);
          }
          if (expectedSize != null && expectedSize != stat.size) {
            throw const SourceException(SourceFailure.invalidData);
          }
          expectedSize = stat.size;
          stream = local.openRead();
        } else {
          final response = await _adapter.transport.send(
            'GET',
            lease.uri,
            headers: lease.headers,
            redirects: true,
            abort: _cancellation.aborted,
          );
          _requireCurrent();
          if (response.statusCode != 200) {
            await response.stream.listen((_) {}).cancel();
            SourceTransport.check(response.statusCode);
            throw const SourceException(SourceFailure.unavailable);
          }
          final responseSize = int.tryParse(response.headers['content-length'] ?? '');
          if (responseSize != null && responseSize > maxBytes) {
            await response.stream.listen((_) {}).cancel();
            throw const SourceException(SourceFailure.invalidData);
          }
          if (expectedSize != null && responseSize != null && expectedSize != responseSize) {
            await response.stream.listen((_) {}).cancel();
            throw const SourceException(SourceFailure.invalidData);
          }
          expectedSize ??= responseSize;
          stream = response.stream;
        }
      }

      var received = 0;
      final output = await target.open(mode: FileMode.write);
      final iterator = StreamIterator<List<int>>(stream);
      try {
        while (true) {
          // Race the next network chunk with the preview's cancel token. A
          // reader closing mid-transfer must release the provider stream
          // immediately instead of waiting for another chunk or the timeout.
          final hasChunk = await Future.any<bool>([
            iterator.moveNext().timeout(const Duration(seconds: 45)),
            _cancellation.aborted.then((_) => false),
          ]);
          _requireCurrent();
          if (!hasChunk) {
            break;
          }
          final chunk = iterator.current;
          if (received + chunk.length > maxBytes || expectedSize != null && received + chunk.length > expectedSize) {
            throw const SourceException(SourceFailure.invalidData);
          }
          await output.writeFrom(chunk);
          received += chunk.length;
        }
        await output.flush();
      } finally {
        await iterator.cancel();
        await output.close();
      }
      _requireCurrent();
      if (received <= 0 || expectedSize != null && received != expectedSize) {
        throw const SourceException(SourceFailure.invalidData);
      }
      return target;
    } catch (_) {
      if (await target.exists()) {
        await target.delete();
      }
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cancellation.cancel();
    try {
      await _opening;
    } on Object {
      // Cancellation is expected when the reader closes mid-transfer.
    }
    final directory = _directory;
    _directory = null;
    if (directory != null) {
      try {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      } on FileSystemException {
        // The app's temporary-directory cleanup will remove a locked preview.
      }
    }
  }
}
