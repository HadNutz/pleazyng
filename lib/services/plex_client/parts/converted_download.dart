part of '../../plex_client.dart';

extension _PlexConvertedDownloads on PlexClient {
  /// A forced Plex video encode does not itself promise HDR-to-SDR conversion.
  /// Require an explicit SDR declaration in the HLS master before calling it
  /// a compatibility rendition, and stop the just-started session if the
  /// output is missing that signal.
  Future<void> _verifyDolbyVisionSdrManifest(String transcodeUrl, String transcodeSessionId) async {
    try {
      final bytes = await _http.getBytes(transcodeUrl, timeout: MediaServerTimeouts.plexProbe, maxBytes: 64 * 1024);
      final manifest = utf8.decode(bytes, allowMalformed: false);
      if (hlsMasterDeclaresSdrVideoOutput(manifest)) {
        appLogger.i('Dolby Vision compatibility transcode declares SDR HLS output');
        return;
      }
      appLogger.w('Plex Dolby Vision encode did not declare SDR output; refusing the unverified rendition');
      throw PlaybackException(t.messages.playbackFailed, reason: PlaybackFailureReason.noPlayableSource);
    } catch (error, stackTrace) {
      try {
        await _getWithFailover(
          '/video/:/transcode/universal/stop',
          queryParameters: {'session': transcodeSessionId},
          timeout: MediaServerTimeouts.plexProbe,
        );
      } catch (stopError, stopStackTrace) {
        appLogger.d(
          'Failed to stop an unverified Plex Dolby Vision transcode',
          error: stopError,
          stackTrace: stopStackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Register the exact selected version/part on the same session that will
  /// read the file. This is advisory: it must never substitute the decision's
  /// URL or force a transcode. A dead decision endpoint gets one bounded try.
  Future<void> _registerDirectPlay(PlexVideoPlaybackData data, MediaItem item, String? sessionId) async {
    if (!item.kind.isVideo || sessionId == null || sessionId.isEmpty || isOfflineMode) return;
    const deadline = Duration(seconds: 5);
    final abort = AbortController();
    try {
      final response = await _http
          .get(
            '/video/:/transcode/universal/decision',
            queryParameters: {
              ..._transcodeClientParams(),
              'path': '/library/metadata/${item.id}',
              'mediaIndex': data.selectedMediaIndex,
              'partIndex': data.selectedPartIndex,
              'hasMDE': 1,
              'protocol': 'http',
              'directPlay': 1,
              'directStream': 1,
              'subtitles': 'none',
              'session': sessionId,
              'X-Plex-Session-Identifier': sessionId,
            },
            headers: {'X-Plex-Session-Identifier': sessionId},
            timeout: deadline,
            abort: abort,
            allowEndpointFailover: false,
          )
          .namedTimeout(deadline, operation: 'plex direct-play registration');
      throwIfHttpError(response);
    } on TimeoutException {
      abort.abort();
      appLogger.d('Plex direct-play registration timed out; trying the selected file');
    } on MediaServerHttpException catch (error) {
      if (error.type == MediaServerHttpErrorType.cancelled) rethrow;
      appLogger.d('Plex direct-play registration unavailable; trying the selected file');
    } catch (_) {
      appLogger.d('Plex direct-play registration failed; trying the selected file');
    }
  }

  Future<ConvertedDownloadState> _requestConvertedDownload(
    MediaItem item, {
    required int mediaIndex,
    required TranscodeQualityPreset preset,
    Future<void> Function(DownloadConversionHandle job)? onAccepted,
  }) async {
    final queueId = _downloadQueueId ??= await _fetchDownloadQueueId();
    final addResponse = await _postWithFailover(
      '/downloadQueue/$queueId/add',
      queryParameters: buildConvertedDownloadParams(ratingKey: item.id, mediaIndex: mediaIndex, preset: preset),
    );
    final added = _getMediaContainer(addResponse)?['AddedQueueItems'];
    final itemId = added is List && added.isNotEmpty && added.first is Map ? (added.first as Map)['id'] : null;
    final id = int.tryParse(itemId?.toString() ?? '');
    if (id == null) return const ConvertedDownloadFailed('Server did not accept the download conversion');
    await onAccepted?.call((queueId: queueId, itemId: id));

    final itemResponse = await _getWithFailover('/downloadQueue/$queueId/items/$itemId');
    final items = _getMediaContainer(itemResponse)?['DownloadQueueItem'];
    final queueItem = items is List && items.isNotEmpty && items.first is Map ? items.first as Map : null;
    if (queueItem == null) return const ConvertedDownloadFailed('Server lost the download conversion');

    final status = queueItem['status']?.toString();
    switch (status) {
      case 'available':
        return ConvertedDownloadReady(
          url: _authenticatedServerUrl('/downloadQueue/$queueId/item/$itemId/media'),
          container: await _convertedDownloadContainer(queueId, itemId),
        );
      case 'processing':
        final session = queueItem['TranscodeSession'];
        final progress = session is Map ? session['progress'] : null;
        return ConvertedDownloadPending(
          percent: progress is num ? progress.clamp(0, 100).floor() : null,
          retryAfter: const Duration(seconds: 15),
        );
      case 'deciding':
        return const ConvertedDownloadPending(retryAfter: Duration(seconds: 3));
      case 'waiting':
        return const ConvertedDownloadPending(retryAfter: Duration(seconds: 30));
      case 'expired':
        // The finished file aged out before it was fetched; convert it again.
        await _postWithFailover('/downloadQueue/$queueId/items/$itemId/restart');
        return const ConvertedDownloadPending(retryAfter: Duration(seconds: 15));
      default:
        final decision = queueItem['DecisionResult'];
        final reason =
            queueItem['error']?.toString() ??
            (decision is Map ? decision['transcodeDecisionText'] ?? decision['generalDecisionText'] : null)
                ?.toString() ??
            'Server could not convert the download (status ${status ?? 'unknown'})';
        return ConvertedDownloadFailed(reason);
    }
  }
}
