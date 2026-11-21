part of '../download_manager_service.dart';

extension _DownloadServerConversion on DownloadManagerService {
  Future<T> _serializeConversion<T>(String key, Future<T> Function() operation) {
    final result = (_conversionTails[key] ?? Future<void>.value()).then((_) => operation());
    final tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _conversionTails[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_conversionTails[key], tail)) _conversionTails.remove(key);
      }),
    );
    return result;
  }

  /// The quality [row] was queued to be converted to, or null for the
  /// original file (including an unknown name from a newer build).
  TranscodeQualityPreset? _storedDownloadQuality(DownloadedMediaItem row) {
    final name = row.downloadQuality;
    if (name == null) return null;
    final preset = TranscodeQualityPreset.values.asNameMap()[name];
    return preset == null || preset.isOriginal ? null : preset;
  }

  /// Ask the server to convert [globalKey] to [quality] and return the
  /// resolution to fetch once the converted file is ready.
  ///
  /// Returns null while the server is still working: the row stays
  /// downloading with the conversion progress on it, and a timer re-runs
  /// preparation, whose repeat request finds the same server job. A backend
  /// that cannot convert falls back to [original]. A refused conversion
  /// throws, failing the download like any other preparation error.
  Future<DownloadResolution?> _resolveServerConversion(
    String globalKey,
    MediaServerClient client,
    MediaItem metadata,
    DownloadedMediaItem row,
    TranscodeQualityPreset quality,
    DownloadResolution original,
  ) => _serializeConversion(globalKey, () async {
    if (client is! ConvertedDownloadClient) {
      appLogger.i('Server for $globalKey cannot convert downloads; storing the original file');
      await _database.useOriginalDownloadQuality(globalKey);
      return original;
    }
    // Interfaces are not subtypes of each other, so the check does not promote.
    final converter = client as ConvertedDownloadClient;
    if (_cancellingKeys.contains(globalKey)) return null;
    if (client is CancellableDownloadConversion && !await _cancelRecordedConversions(globalKey, preferred: client)) {
      throw StateError('Waiting to cancel an earlier server conversion');
    }
    final owner = client is CancellableDownloadConversion
        ? (client as CancellableDownloadConversion).downloadConversionOwner
        : null;
    final state = await converter.requestConvertedDownload(
      metadata,
      mediaIndex: row.mediaIndex,
      mediaSourceId: row.mediaSourceId,
      preset: quality,
      onAccepted: owner == null
          ? null
          : (job) async {
              try {
                await _database.recordDownloadConversion(
                  globalKey,
                  client.serverId.value,
                  client.cacheServerId,
                  owner,
                  job,
                );
              } catch (_) {
                // A job whose handle could not be recorded must not keep running anonymously.
                await (client as CancellableDownloadConversion).cancelDownloadConversion(job);
                rethrow;
              }
            },
    );
    if (_cancellingKeys.contains(globalKey)) return null;
    switch (state) {
      case ConvertedDownloadReady(:final url, :final container, :final supportsRangeResume, :final additionalPartUrls):
        appLogger.i('Server conversion of $globalKey to ${quality.name} is ready');
        return DownloadResolution(
          videoUrl: url,
          mediaSourceId: original.mediaSourceId,
          externalSubtitles: original.externalSubtitles,
          externalSubtitlesResolved: original.externalSubtitlesResolved,
          additionalParts: [
            for (final (index, partUrl) in additionalPartUrls.indexed)
              DownloadPartResolution(
                url: partUrl,
                externalSubtitles: index < original.additionalParts.length
                    ? original.additionalParts[index].externalSubtitles
                    : const [],
              ),
          ],
          videoExtension: container,
          supportsRangeResume: supportsRangeResume,
        );
      case ConvertedDownloadPending(:final percent, :final retryAfter):
        // Paused, cancelled, or deleted while the server answered.
        final current = await _database.getDownloadedMedia(globalKey);
        if (_cancellingKeys.contains(globalKey) || current?.status != DownloadStatus.downloading.index) return null;
        appLogger.d(
          'Server still converting $globalKey (${percent ?? '-'}%); checking again in ${retryAfter.inSeconds}s',
        );
        if (!_disposed) {
          _progressController.add(
            DownloadProgress(
              globalKey: globalKey,
              status: DownloadStatus.downloading,
              serverConverting: true,
              serverConversionPercent: percent,
            ),
          );
        }
        _serverConversionTimers.remove(globalKey)?.cancel();
        if (!_disposed) {
          _serverConversionTimers[globalKey] = Timer(retryAfter, () {
            _serverConversionTimers.remove(globalKey);
            _trackBackgroundOperation(_pollServerConversion(globalKey, client), 'server conversion poll');
          });
        }
        return null;
      case ConvertedDownloadFailed(:final reason):
        throw StateError(reason);
    }
  });

  Future<void> _resumeConversionCancellations(MediaServerClient client) async {
    final rows = await _database.cancelledDownloadConversions(server: client.serverId.value);
    for (final key in rows.map((row) => row.read<String>('global_key')).toSet()) {
      await _serializeConversion(key, () => _cancelRecordedConversions(key, preferred: client));
    }
  }

  /// An offline cancellation outlives the local download row. Only its original
  /// server account and device queue may remove the recorded job.
  Future<bool> _cancelRecordedConversions(String key, {MediaServerClient? preferred}) async {
    var settled = true;
    for (final row in await _database.cancelledDownloadConversions(key: key)) {
      final server = ServerId(row.read<String>('server_id'));
      final scope = row.read<String>('scope_id');
      final owner = row.read<String>('owner');
      bool matches(MediaServerClient? client) =>
          client is CancellableDownloadConversion &&
          client!.serverId == server &&
          client.cacheServerId == scope &&
          (client as CancellableDownloadConversion).downloadConversionOwner == owner;
      final client = matches(preferred) ? preferred : _getClient(server, clientScopeId: scope == server ? null : scope);
      if (!matches(client)) continue;
      try {
        await (client as CancellableDownloadConversion).cancelDownloadConversion((
          queueId: row.read<int>('queue_id'),
          itemId: row.read<int>('item_id'),
        ));
        await _database.forgetDownloadConversion(row);
      } catch (error) {
        appLogger.w('Server download cancellation deferred for $key', error: error);
        settled = false;
      }
    }
    return settled;
  }

  /// Re-run preparation for a download that was waiting on the server's
  /// conversion, unless it was paused, cancelled, or finished meanwhile.
  Future<void> _pollServerConversion(String globalKey, MediaServerClient fallbackClient) async {
    if (_disposed || _queueBlockedByStorageFailure) return;
    final row = await _database.getDownloadedMedia(globalKey);
    if (row == null || row.status != DownloadStatus.downloading.index || row.bgTaskId != null) return;
    final queueItem = await _queueItemFor(globalKey);
    if (queueItem == null) return;
    final client = await _getClientForDownloadKey(globalKey) ?? fallbackClient;
    await _prepareAndEnqueueDownload(globalKey, client, queueItem);
  }
}
