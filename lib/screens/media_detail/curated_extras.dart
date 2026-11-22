part of '../media_detail_screen.dart';

extension _DetailCuratedExtras on _MediaDetailScreenState {
  List<MediaItem>? get _extraPreviews => _curatedExtras?.preview.map(extraDisplayItem).toList();

  ExtraEntry? _extraForDisplay(MediaItem item) =>
      _curatedExtras?.entries.where((e) => 'extra:${e.id}' == item.id).firstOrNull;

  Future<void> _syncCuratedExtras() async {
    final generation = ++_extrasLoadGeneration;
    bool currentGeneration() => _canUseDetail && generation == _extrasLoadGeneration;
    if (!_canUseDetail || (!_metadata.isMovie && !_metadata.isShow)) return;
    final locale = WidgetsBinding.instance.platformDispatcher.locale;
    final subject = extrasSubjectForMedia(
      _fullMetadata ?? _metadata,
      restricted: extrasRestricted(context),
      offline: widget.isOffline,
      language: LocaleSettings.currentLocale.languageCode,
      region: locale.countryCode ?? 'US',
    );
    final session = _curatedExtras;
    if (session == null) {
      _curatedExtras = createExtrasSession(
        context,
        subject,
        library: _extras ?? const [],
        isCurrent: () => _canUseDetail,
      )..addListener(_extrasChanged);
    } else {
      session.subject = subject;
      session.library = _extras ?? const [];
    }
    final current = _curatedExtras!;
    try {
      if (widget.isOffline) {
        final downloads = context.read<DownloadProvider>();
        final restored = <MediaItem>[];
        for (final ref in await current.store.libraryReferences(subject.key)) {
          if (!current.active || !currentGeneration()) return;
          final cached = await downloads.lookupOfflineMetadata(ServerId(ref.serverId), ref.id);
          final item = cached?.copyWith(serverId: ref.serverId);
          if (item != null && downloads.isDownloaded(item.globalKey)) restored.add(item);
        }
        if (!current.active || !currentGeneration()) return;
        current.library = restored;
      } else if (_hasLoadedExtras && _extras != null) {
        await current.store.saveLibraryReferences(subject.key, [
          for (final item in _extras!)
            if (item.serverId != null) (serverId: item.serverId!, id: item.id),
        ]);
      }
    } catch (_) {
      /* best-effort: Missing offline metadata leaves an empty native selection. */
    }
    if (current.active && currentGeneration()) await current.refresh();
  }

  void _browseExtras() {
    final session = _curatedExtras;
    if (session != null && session.active) unawaited(openExtras(context, session));
  }

  void _activateExtraPreview(MediaItem item) {
    final entry = _extraForDisplay(item), session = _curatedExtras;
    if (entry != null && session != null) unawaited(playExtra(context, session, entry));
  }
}
