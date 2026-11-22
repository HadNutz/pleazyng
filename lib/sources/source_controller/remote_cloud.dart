part of '../source_controller.dart';

extension _SourceRemoteCloud on SourceController {
  Future<void> _reconcileRemoteCloudSources(int epoch) async {
    await ready;
    if (!current(epoch) || loading || blocked || profileId == null) {
      return;
    }
    final remote = _remoteStreamingProvider;
    if (remote == null || remote.profileId != profileId || remote.loading) {
      return;
    }
    if (remote.loadFailed || !remote.isReady) {
      final visible = sources.where((source) => source.kind != FileSourceKind.remoteCloud).toList(growable: false);
      if (visible.length != sources.length) {
        sources = visible;
        for (final id in _remoteSourceIds) {
          _adapters.remove(id)?.close();
        }
        await _shelves(profileId!, epoch);
        _notify();
      }
      return;
    }

    final profile = profileId!;
    final metadataPreference = await repository.preference(profile, _remoteCloudMetadataPreference);
    if (!current(epoch) || profileId != profile) {
      return;
    }
    final onlineMetadata = metadataPreference['enabled'] == 'true' ? 'true' : 'false';
    final remoteSources = [
      for (final account in remote.accounts)
        FileSource(
          id: 'remote-cloud:${account.id}',
          profileId: profile,
          kind: FileSourceKind.remoteCloud,
          name: account.displayName,
          endpoint: 'remote-cloud://${account.service.name}/${Uri.encodeComponent(account.id)}',
          options: {'accountId': account.id, 'service': account.service.name, 'onlineMetadata': onlineMetadata},
        ),
    ];
    final nextIds = remoteSources.map((source) => source.id).toSet();
    final removedIds = _remoteSourceIds.difference(nextIds);
    for (final id in removedIds) {
      _adapters.remove(id)?.close();
      await repository.removeSource(profile, id);
      if (!current(epoch)) {
        return;
      }
    }
    if (!remote.isReady ||
        remote.profileId != profile ||
        remote.accounts.length != remoteSources.length ||
        remote.accounts.any(
          (account) => !remoteSources.any(
            (source) =>
                source.options['accountId'] == account.id &&
                source.options['service'] == account.service.name &&
                source.name == account.displayName,
          ),
        )) {
      _remoteStreamingChanged();
      return;
    }
    final nextSources = [...sources.where((source) => source.kind != FileSourceKind.remoteCloud), ...remoteSources];
    _remoteSourceIds
      ..clear()
      ..addAll(nextIds);
    final previousRemoteById = {
      for (final source in sources.where((source) => source.kind == FileSourceKind.remoteCloud)) source.id: source,
    };
    final changed =
        previousRemoteById.length != remoteSources.length ||
        remoteSources.any((source) {
          final previous = previousRemoteById[source.id];
          return previous == null ||
              previous.profileId != source.profileId ||
              previous.name != source.name ||
              previous.endpoint != source.endpoint ||
              previous.options['service'] != source.options['service'] ||
              previous.options['accountId'] != source.options['accountId'] ||
              previous.options['onlineMetadata'] != source.options['onlineMetadata'];
        });
    sources = nextSources;
    if (!changed) {
      return;
    }
    await _shelves(profile, epoch);
    if (!current(epoch)) {
      return;
    }
    await downloads.restoreProfile(profile, (sourceId) {
      if (!current(epoch) || !sources.any((source) => source.id == sourceId)) {
        return null;
      }
      try {
        return adapter(sourceId);
      } on Object {
        return null;
      }
    });
    if (!current(epoch)) {
      return;
    }
    _notify();
    for (final source in remoteSources) {
      unawaited(_warmRemoteCloudIndex(source, epoch).catchError((Object _) {}));
    }
  }

  Future<void> _warmRemoteCloudIndex(FileSource source, int epoch) async {
    if (!current(epoch) || source.kind != FileSourceKind.remoteCloud || source.profileId != profileId) {
      return;
    }
    final profile = source.profileId;
    final preferenceKey = 'remote-cloud-index-warm-v1:${source.id}';
    final previous = await repository.preference(profile, preferenceKey);
    if (!current(epoch) || !sources.any((value) => value.id == source.id)) {
      return;
    }
    final lastIndexedAt = int.tryParse(previous['completedAt'] ?? '');
    if (lastIndexedAt != null &&
        DateTime.now().millisecondsSinceEpoch - lastIndexedAt < const Duration(hours: 12).inMilliseconds) {
      return;
    }

    // Index one recent page of cloud containers, then only a small number of
    // their contents. This gives Home and the video shelf useful poster rows
    // without turning profile startup into an account-wide inventory crawl.
    final root = await browse(source.id);
    if (!current(epoch)) {
      return;
    }
    final folders = <({SourceEntry entry, int depth})>[
      for (final entry in root.entries.where((entry) => entry.isFolder)) (entry: entry, depth: 1),
    ];
    final visited = <String>{};
    var folderIndex = 0;
    var indexedEntries = root.entries.length;
    while (folderIndex < folders.length && folderIndex < 12 && indexedEntries < 1200) {
      if (!current(epoch) || !sources.any((value) => value.id == source.id)) {
        return;
      }
      final folder = folders[folderIndex++];
      if (folder.depth > 4 || !visited.add(folder.entry.id)) {
        continue;
      }
      final page = await browse(source.id, parent: folder.entry.id);
      if (!current(epoch)) {
        return;
      }
      indexedEntries += page.entries.length;
      for (final child in page.entries.where((entry) => entry.isFolder)) {
        if (folders.length < 120) {
          folders.add((entry: child, depth: folder.depth + 1));
        }
      }
    }
    if (!current(epoch)) {
      return;
    }
    await repository.savePreference(profile, preferenceKey, {
      'completedAt': '${DateTime.now().millisecondsSinceEpoch}',
      'indexedEntries': '$indexedEntries',
    });
  }

  RemoteCloudSourceAdapter _remoteCloudAdapter(FileSource source, SourceTransport transport, int epoch) {
    final remote = _remoteStreamingProvider;
    final accountId = source.options['accountId'];
    final serviceName = source.options['service'];
    final service = RemoteStreamService.values.where((value) => value.name == serviceName).firstOrNull;
    if (remote == null || accountId == null || service == null) {
      throw const SourceException(SourceFailure.authentication);
    }
    void checkAccount() {
      requireSession(epoch);
      if (!remote.isReady || remote.profileId != source.profileId || remote.accountFor(service)?.id != accountId) {
        throw const SourceException(SourceFailure.cancelled);
      }
    }

    Future<RemoteCloudPage> loadPage({String? parentId, String? cursor}) async {
      checkAccount();
      final result = await remote.browseCloud(service, parentId: parentId, cursor: cursor);
      checkAccount();
      return result;
    }

    Future<ContentLease> resolveContent(RemoteCloudItem item) async {
      checkAccount();
      if (item.accountId != accountId || item.service != service) {
        throw const SourceException(SourceFailure.cancelled);
      }
      final resolved = await remote.resolveCloudFile(item);
      checkAccount();
      final size = resolved.size ?? item.size;
      final account = remote.accountFor(service);
      final canRefresh =
          account != null &&
          account.id == accountId &&
          size != null &&
          size > 0 &&
          item.providerId != null &&
          item.providerFileId != null;
      final backgroundRefresh = canRefresh
          ? <String, dynamic>{
              'provider': 'remoteCloud',
              'service': service.name,
              'accountId': accountId,
              'accessToken': account.accessToken,
              if (account.refreshToken != null) 'refreshToken': account.refreshToken,
              if (account.clientId != null) 'clientId': account.clientId,
              if (account.clientSecret != null) 'clientSecret': account.clientSecret,
              if (account.expiresAt != null) 'expiresAt': account.expiresAt,
              'providerId': item.providerId,
              'providerFileId': item.providerFileId,
              if (item.parentProviderId != null) 'parentProviderId': item.parentProviderId,
              'size': size,
              'revision': service == RemoteStreamService.premiumize
                  ? 'premiumize:${item.parentProviderId ?? 'root'}:${item.providerFileId}:$size'
                  : '${service.name}:${item.providerId}:${item.providerFileId}:$size',
            }
          : null;
      return ContentLease(
        resolved.uri,
        size: size,
        // Treat provider links as short-lived capabilities: native tasks use
        // the encrypted recipe below to request this exact file again.
        expiresAt: canRefresh ? DateTime.now().add(const Duration(minutes: 10)) : null,
        backgroundTransferSafe: canRefresh,
        backgroundRefresh: backgroundRefresh,
      );
    }

    Future<String?> loadParentProviderId(String entryId) async {
      checkAccount();
      final entry = await repository.entryById(source.profileId, source.id, entryId);
      checkAccount();
      if (entry == null || !entry.isFolder) {
        return null;
      }
      final providerId = entry.identifiers['remoteCloudProviderId'];
      if (providerId == null || providerId.isEmpty || providerId.length > 256) {
        return null;
      }
      return providerId;
    }

    Future<SourceEntry?> loadEntryById(String entryId) async {
      checkAccount();
      final entry = await repository.entryById(source.profileId, source.id, entryId);
      checkAccount();
      return entry;
    }

    return RemoteCloudSourceAdapter(
      source,
      transport,
      service: service,
      accountId: accountId,
      loadPage: loadPage,
      resolveContent: resolveContent,
      loadParentProviderId: loadParentProviderId,
      loadEntryById: loadEntryById,
    );
  }
}
