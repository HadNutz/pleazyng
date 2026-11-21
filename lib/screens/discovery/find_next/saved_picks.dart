part of '../find_next_screen.dart';

class _SavedPicksScreen extends StatefulWidget {
  const _SavedPicksScreen({
    required this.profileId,
    required this.store,
    required this.includeCatalog,
    required this.syncSavedPicks,
    required this.onOpen,
    required this.onChooseForMe,
    required this.onChooseTogether,
    required this.onChanged,
  });
  final String profileId;
  final DiscoveryStore store;
  final bool includeCatalog;
  final bool syncSavedPicks;
  final ValueChanged<DiscoveryChoice> onOpen;
  final ValueChanged<List<DiscoveryChoice>> onChooseForMe;
  final ValueChanged<DiscoveryChoice> onChooseTogether;
  final Future<void> Function() onChanged;
  @override
  State<_SavedPicksScreen> createState() => _SavedPicksScreenState();
}

class _SavedPicksScreenState extends State<_SavedPicksScreen> {
  DiscoveryState _state = const DiscoveryState();
  final TextEditingController _searchController = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  bool _searching = false;
  bool _compareMode = false;
  bool _voteMode = false;
  bool _comparing = false;
  bool _voting = false;
  int _sourceGeneration = -1;
  final Set<String> _comparisonIds = {};
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final sources = context.read<SourceController>();
    if (sources.profileId != widget.profileId || sources.blocked) return;
    _sourceGeneration = sources.generation;
    final state = await widget.store.load(widget.profileId);
    if (!mounted ||
        !sources.current(_sourceGeneration) ||
        sources.profileId != widget.profileId ||
        context.read<ActiveProfileProvider>().active?.id != widget.profileId) {
      return;
    }
    setState(() {
      _state = state;
      _loading = false;
    });
  }

  Future<void> _remove(DiscoveryChoice choice) async {
    if (_busy || context.read<ActiveProfileProvider>().active?.id != widget.profileId) {
      return;
    }
    setState(() => _busy = true);
    try {
      final state = await widget.store.decide(widget.profileId, choice, DiscoveryDecisionAction.removeSaved);
      if (!mounted || context.read<ActiveProfileProvider>().active?.id != widget.profileId) {
        return;
      }
      setState(() {
        _state = state;
        _comparisonIds.remove(choice.id);
      });
      context.read<SourceController>().scheduleSync();
      await widget.onChanged();
    } catch (_) {
      if (mounted) showErrorSnackBar(context, t.discover.findNext.changeFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _undo() async {
    if (_busy || _state.history.isEmpty || context.read<ActiveProfileProvider>().active?.id != widget.profileId) {
      return;
    }
    final savedChanged = _state.history.last.savedChanged;
    setState(() => _busy = true);
    try {
      final (state, _) = await widget.store.undo(widget.profileId);
      if (!mounted || context.read<ActiveProfileProvider>().active?.id != widget.profileId) {
        return;
      }
      setState(() => _state = state);
      if (savedChanged) context.read<SourceController>().scheduleSync();
      await widget.onChanged();
    } on DiscoveryUndoLimitException {
      if (mounted) showErrorSnackBar(context, t.discover.findNext.savedLimit);
    } catch (_) {
      if (mounted) showErrorSnackBar(context, t.discover.findNext.changeFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleSearch() {
    if (_searching) _searchController.clear();
    setState(() {
      _searching = !_searching;
      _query = '';
    });
  }

  void _toggleCompareMode() {
    setState(() {
      _compareMode = !_compareMode;
      _voteMode = false;
      _comparisonIds.clear();
    });
  }

  void _toggleVoteMode() {
    setState(() {
      _voteMode = !_voteMode;
      _compareMode = false;
      _comparisonIds.clear();
    });
  }

  void _toggleComparison(DiscoveryChoice choice) {
    if (_comparisonIds.contains(choice.id)) {
      setState(() => _comparisonIds.remove(choice.id));
      return;
    }
    if (_comparisonIds.length >= (_voteMode ? 12 : 3)) {
      showErrorSnackBar(context, _voteMode ? t.discover.findNext.voteLimit : t.discover.findNext.compareLimit);
      return;
    }
    setState(() => _comparisonIds.add(choice.id));
  }

  Future<void> _startVoting(List<DiscoveryChoice> choices) async {
    if (_voting || _comparisonIds.length < 2 || _comparisonIds.length > 12) {
      return;
    }
    final sources = context.read<SourceController>();
    if (!sources.current(_sourceGeneration) || sources.profileId != widget.profileId || sources.blocked) {
      return;
    }
    final selected = choices.where((choice) => _comparisonIds.contains(choice.id)).take(12).toList(growable: false);
    if (selected.length < 2) {
      showErrorSnackBar(context, t.discover.findNext.voteLimit);
      return;
    }
    setState(() => _voting = true);
    try {
      final choice = await Navigator.of(context).push<DiscoveryChoice>(
        MaterialPageRoute(
          builder: (_) => DiscoveryShortlistVoteScreen(profileId: widget.profileId, choices: selected),
        ),
      );
      sources.requireSession(_sourceGeneration);
      if (choice != null && mounted && context.read<ActiveProfileProvider>().active?.id == widget.profileId) {
        widget.onChooseTogether(choice);
      }
    } catch (_) {
      if (mounted) showErrorSnackBar(context, t.discover.findNext.changeFailed);
    } finally {
      if (mounted) setState(() => _voting = false);
    }
  }

  Future<void> _compareSelected(List<DiscoveryChoice> choices) async {
    if (_comparing || _comparisonIds.length < 2) return;
    final sources = context.read<SourceController>();
    if (!sources.current(_sourceGeneration) || sources.profileId != widget.profileId) {
      return;
    }
    setState(() => _comparing = true);
    try {
      final selected = choices.where((choice) => _comparisonIds.contains(choice.id)).toList(growable: false);
      if (selected.length < 2) {
        if (mounted) {
          setState(() => _comparisonIds.removeWhere((id) => !choices.any((choice) => choice.id == id)));
          showErrorSnackBar(context, t.discover.findNext.compareNeedsTwo);
        }
        return;
      }
      final facts = await Future.wait(selected.map(_comparisonFacts));
      sources.requireSession(_sourceGeneration);
      if (!mounted || context.read<ActiveProfileProvider>().active?.id != widget.profileId) {
        return;
      }
      await OverlaySheetController.showAdaptive<void>(
        context,
        showDragHandle: true,
        builder: (sheetContext) {
          final screenHeight = MediaQuery.sizeOf(sheetContext).height;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: screenHeight * 0.84),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(t.common.compare, style: Theme.of(sheetContext).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = constraints.maxWidth >= 720;
                        if (wide) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var index = 0; index < facts.length; index++) ...[
                                if (index > 0) const SizedBox(width: 12),
                                Expanded(child: _comparisonCard(context, facts[index])),
                              ],
                            ],
                          );
                        }
                        return ListView.separated(
                          itemCount: facts.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 12),
                          itemBuilder: (context, index) => _comparisonCard(context, facts[index]),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(onPressed: () => Navigator.of(sheetContext).pop(), child: Text(t.common.close)),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } catch (_) {
      if (mounted) showErrorSnackBar(context, t.discover.findNext.openFailed);
    } finally {
      if (mounted) setState(() => _comparing = false);
    }
  }

  Future<_SavedPickFacts> _comparisonFacts(DiscoveryChoice choice) async {
    final sources = context.read<SourceController>();
    sources.requireSession(_sourceGeneration);
    final downloads = context.read<DownloadProvider>();
    var entry = choice.sourceEntry;
    if (entry == null && choice.sourceId != null && choice.entryId != null) {
      try {
        entry = await sources.repository.entryById(widget.profileId, choice.sourceId!, choice.entryId!);
        sources.requireSession(_sourceGeneration);
      } catch (_) {
        appLogger.d('Could not read the saved entry for comparison.');
      }
    }
    if (entry == null &&
        choice.portableKey != null &&
        (choice.type == DiscoveryChoiceType.ebook ||
            choice.type == DiscoveryChoiceType.audiobook ||
            choice.type == DiscoveryChoiceType.comic ||
            choice.type == DiscoveryChoiceType.music ||
            choice.type == DiscoveryChoiceType.sourceVideo)) {
      try {
        final configured = {for (final source in sources.sources) source.id};
        entry =
            (await sources.repository.entriesByPublicIdentifiers(
                  widget.profileId,
                  choice.portableIds,
                  kind: _sourceKindForPortableChoice(choice),
                  sourceIds: configured,
                ))
                .where(
                  (candidate) =>
                      discoveryTypeForSourceKind(candidate.kind) == choice.type &&
                      configured.contains(candidate.sourceId) &&
                      _sharesPublicId(choice.portableIds, sanitizeDiscoveryPortableIds(candidate.identifiers)),
                )
                .firstOrNull;
        sources.requireSession(_sourceGeneration);
      } catch (_) {
        appLogger.d('Could not match a saved entry by its public identifier.');
      }
    }
    var offline = false;
    var language = '';
    var narrator = '';
    var edition = '';
    if (entry != null) {
      language = entry.language.trim();
      narrator = entry.narrator.trim();
      final ordinary = entry.files.where((file) => !file.sampleOnly).toList(growable: false);
      edition = ordinary.map((file) => isolateDisplayText(file.name)).take(4).join('\n');
      for (final file in ordinary) {
        if (await sources.hasOfflineContent(entry, file)) {
          sources.requireSession(_sourceGeneration);
          offline = true;
          break;
        }
        sources.requireSession(_sourceGeneration);
      }
    } else if (choice.serverId != null && choice.mediaId != null) {
      final media =
          choice.mediaItem ??
          downloads.metadata.values
              .where((item) => item.serverId == choice.serverId && item.id == choice.mediaId)
              .firstOrNull;
      if (media != null && await downloads.getCompletedDownload(media.globalKey) != null) {
        try {
          if (media.kind == MediaKind.movie || media.kind == MediaKind.episode || media.kind == MediaKind.clip) {
            offline = await downloads.getVideoFilePath(media.globalKey).timeout(const Duration(seconds: 2)) != null;
          }
        } catch (_) {
          appLogger.d('Could not determine offline availability for comparison.');
        }
      }
    } else if (choice.type == DiscoveryChoiceType.video &&
        (choice.mediaKind == MediaKind.movie || choice.mediaKind == MediaKind.show)) {
      final media = await _findPortableLibraryCopy(choice);
      sources.requireSession(_sourceGeneration);
      if (media != null && await downloads.getCompletedDownload(media.globalKey) != null) {
        try {
          if (media.kind == MediaKind.movie || media.kind == MediaKind.episode || media.kind == MediaKind.clip) {
            offline = await downloads.getVideoFilePath(media.globalKey).timeout(const Duration(seconds: 2)) != null;
          }
        } catch (_) {
          appLogger.d('Could not determine offline availability for comparison.');
        }
      }
    }
    return _SavedPickFacts(
      title: isolateDisplayText(choice.title),
      type: _localizedChoiceType(choice),
      localOnly: widget.syncSavedPicks && choice.portableKey == null,
      duration: choice.totalDurationMs ?? choice.durationMs,
      language: language.isEmpty ? t.common.notAvailable : language,
      narrator: narrator.isEmpty ? t.common.notAvailable : isolateDisplayText(narrator),
      edition: edition.isEmpty ? t.common.notAvailable : edition,
      availability: offline ? t.fileSources.offline : t.discover.findNext.availabilityNotChecked,
      summary: isolateDisplayText(choice.summary).trim().isEmpty
          ? t.common.notAvailable
          : isolateDisplayText(choice.summary),
    );
  }

  bool _sharesPublicId(Map<String, String> left, Map<String, String> right) =>
      left.entries.any((entry) => right[entry.key] == entry.value);

  Future<MediaItem?> _findPortableLibraryCopy(DiscoveryChoice choice) async {
    final sourceController = context.read<SourceController>();
    if (!sourceController.current(_sourceGeneration) || sourceController.profileId != widget.profileId) {
      return null;
    }
    final ids = ExternalIds(
      imdb: choice.portableIds['imdb'],
      tmdb: int.tryParse(choice.portableIds['tmdb'] ?? ''),
      tvdb: int.tryParse(choice.portableIds['tvdb'] ?? ''),
    );
    if (!ids.hasCatalogIds) return null;
    try {
      final multiServer = context.read<MultiServerProvider>();
      final result = await multiServer.aggregationService.findByExternalIdsAcrossServers(
        ids,
        kind: choice.mediaKind!,
        serverIds: multiServer.expectedServerIds.toSet(),
        titles: [choice.title],
      );
      if (!sourceController.current(_sourceGeneration) || sourceController.profileId != widget.profileId) {
        return null;
      }
      if (!mounted || context.read<ActiveProfileProvider>().active?.id != widget.profileId) {
        return null;
      }
      final hidden = context.read<HiddenLibrariesProvider>().hiddenLibraryKeys;
      final libraries = context.read<LibrariesProvider>().libraries;
      return result.items.where((item) {
        if (item.kind != choice.mediaKind) return false;
        final libraryId = item.libraryId;
        final serverId = item.serverId;
        if (libraryId == null || serverId == null) return true;
        final key = buildGlobalKey(ServerId(serverId), libraryId);
        return !hidden.contains(key) && libraries.any((library) => library.globalKey == key);
      }).firstOrNull;
    } catch (_) {
      // best-effort: Keep the saved pick available if its library copy cannot be located.
      return null;
    }
  }

  Widget _comparisonCard(BuildContext context, _SavedPickFacts facts) {
    final theme = Theme.of(context);
    Widget field(String label, String value) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 3),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
    return Card(
      margin: EdgeInsets.zero,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(facts.title, style: theme.textTheme.titleMedium, maxLines: 3, overflow: TextOverflow.ellipsis),
            field(t.fileInfo.mediaType, facts.type),
            if (widget.syncSavedPicks)
              field(t.discover.findNext.syncSavedPicks, facts.localOnly ? t.discover.findNext.localOnly : t.common.yes),
            field(
              t.fileInfo.duration,
              facts.duration == null ? t.common.notAvailable : formatDurationTextual(facts.duration!),
            ),
            field(t.fileInfo.language, facts.language),
            field(t.fileSources.narrator, facts.narrator),
            field(t.fileSources.editions, facts.edition),
            field(t.discover.findNext.availability, facts.availability),
            field(t.discover.overview, facts.summary),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeProfile = context.watch<ActiveProfileProvider>().active;
    final sources = context.watch<SourceController>();
    final profileChanged =
        activeProfile?.id != widget.profileId ||
        sources.profileId != widget.profileId ||
        sources.blocked ||
        !sources.current(_sourceGeneration);
    final savedChoices = _state.saved
        .where((choice) => widget.includeCatalog || choice.catalogSourceId == null)
        .toList();
    final query = _query.trim().toLowerCase();
    final visibleChoices = query.isEmpty
        ? savedChoices
        : savedChoices
              .where(
                (choice) => [
                  choice.title,
                  choice.subtitle,
                  choice.reason,
                  _localizedChoiceType(choice),
                ].join('\n').toLowerCase().contains(query),
              )
              .toList(growable: false);
    final canUndo =
        _state.history.isNotEmpty && (widget.includeCatalog || _state.history.last.choice.catalogSourceId == null);
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(hintText: t.common.search, border: InputBorder.none, isDense: true),
                onChanged: (value) => setState(() => _query = value),
              )
            : Text(
                _compareMode || _voteMode
                    ? t.libraries.selection.selectedCount(count: localizeDecimalDigits('${_comparisonIds.length}'))
                    : t.discover.findNext.saved,
              ),
        actions: [
          if (_compareMode || _voteMode)
            IconButton(
              tooltip: t.common.close,
              onPressed: profileChanged || _busy || _comparing || _voting
                  ? null
                  : _voteMode
                  ? _toggleVoteMode
                  : _toggleCompareMode,
              icon: const AppIcon(Symbols.close_rounded),
            )
          else
            IconButton(
              tooltip: t.discover.findNext.selectToCompare,
              onPressed: profileChanged || _busy || _searching || savedChoices.length < 2 ? null : _toggleCompareMode,
              icon: const AppIcon(Symbols.compare_arrows_rounded),
            ),
          if (!_compareMode && !_voteMode)
            IconButton(
              tooltip: t.discover.findNext.selectToVote,
              onPressed: profileChanged || _busy || _searching || savedChoices.length < 2 ? null : _toggleVoteMode,
              icon: const AppIcon(Symbols.groups_rounded),
            ),
          if (_compareMode)
            FocusableButton(
              onPressed: profileChanged || _busy || _comparing || _comparisonIds.length < 2
                  ? null
                  : () => _compareSelected(savedChoices),
              autoScroll: false,
              child: TextButton.icon(
                onPressed: profileChanged || _busy || _comparing || _comparisonIds.length < 2
                    ? null
                    : () => _compareSelected(savedChoices),
                icon: const AppIcon(Symbols.compare_arrows_rounded),
                label: Text(t.common.compare),
              ),
            ),
          if (_voteMode)
            FocusableButton(
              onPressed: profileChanged || _busy || _voting || _comparisonIds.length < 2
                  ? null
                  : () => _startVoting(savedChoices),
              autoScroll: false,
              child: TextButton.icon(
                onPressed: profileChanged || _busy || _voting || _comparisonIds.length < 2
                    ? null
                    : () => _startVoting(savedChoices),
                icon: const AppIcon(Symbols.groups_rounded),
                label: Text(t.discover.findNext.startVote),
              ),
            ),
          if (_searching || savedChoices.isNotEmpty)
            IconButton(
              tooltip: _searching ? t.common.close : t.common.search,
              onPressed: profileChanged ? null : _toggleSearch,
              icon: AppIcon(_searching ? Symbols.close_rounded : Symbols.search_rounded),
            ),
          if (!_compareMode && !_voteMode)
            IconButton(
              tooltip: t.common.shuffle,
              onPressed: _busy || visibleChoices.isEmpty || profileChanged
                  ? null
                  : () => widget.onChooseForMe(visibleChoices),
              icon: const AppIcon(Symbols.shuffle_rounded),
            ),
          if (!_compareMode && !_voteMode)
            FocusableButton(
              onPressed: _busy || !canUndo || profileChanged ? null : _undo,
              autoScroll: false,
              child: TextButton.icon(
                onPressed: _busy || !canUndo || profileChanged ? null : _undo,
                icon: const AppIcon(Symbols.undo_rounded),
                label: Text(t.discover.findNext.undo),
              ),
            ),
        ],
      ),
      body: profileChanged
          ? const SizedBox.shrink()
          : _loading
          ? const Center(child: CircularProgressIndicator())
          : savedChoices.isEmpty
          ? Center(child: Text(t.discover.findNext.noPicks))
          : visibleChoices.isEmpty
          ? Center(child: Text(t.messages.noResultsFound))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: visibleChoices.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final choice = visibleChoices[index];
                final selectedForComparison = _comparisonIds.contains(choice.id);
                return FocusableListTile(
                  autofocus: index == 0 && !_searching,
                  leading: CircleAvatar(child: AppIcon(_savedIcon(choice), size: 22)),
                  title: Text(isolateDisplayText(choice.title), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      _localizedChoiceType(choice),
                      isolateDisplayText(choice.subtitle),
                      if (choice.publicCatalogWorkId != null) t.discover.findNext.catalogOnly,
                      if (choice.lendingLibraryId != null) isolateDisplayText(choice.reason),
                      if (widget.syncSavedPicks && choice.portableKey == null) t.discover.findNext.localOnly,
                      choice.durationMs == null ? null : formatDurationTextual(choice.durationMs!),
                    ].whereType<String>().where((value) => value.isNotEmpty).join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: _busy || profileChanged || _voting
                      ? null
                      : _compareMode || _voteMode
                      ? () => _toggleComparison(choice)
                      : () => widget.onOpen(choice),
                  trailing: IconButton(
                    tooltip: _compareMode
                        ? t.discover.findNext.selectToCompare
                        : _voteMode
                        ? t.discover.findNext.selectToVote
                        : t.common.delete,
                    onPressed: _busy || profileChanged || _voting
                        ? null
                        : _compareMode || _voteMode
                        ? () => _toggleComparison(choice)
                        : () => _remove(choice),
                    icon: AppIcon(
                      _compareMode
                          ? selectedForComparison
                                ? Symbols.check_circle_rounded
                                : Symbols.radio_button_unchecked_rounded
                          : Symbols.bookmark_remove_rounded,
                    ),
                  ),
                );
              },
            ),
    );
  }

  IconData _savedIcon(DiscoveryChoice choice) => switch (choice.type) {
    DiscoveryChoiceType.video || DiscoveryChoiceType.sourceVideo => Symbols.movie_rounded,
    DiscoveryChoiceType.music => Symbols.album_rounded,
    DiscoveryChoiceType.audiobook => Symbols.headphones_rounded,
    DiscoveryChoiceType.ebook => Symbols.menu_book_rounded,
    DiscoveryChoiceType.comic => Symbols.auto_stories_rounded,
    DiscoveryChoiceType.liveProgram => Symbols.live_tv_rounded,
  };
}

class _SavedPickFacts {
  const _SavedPickFacts({
    required this.title,
    required this.type,
    required this.localOnly,
    required this.duration,
    required this.language,
    required this.narrator,
    required this.edition,
    required this.availability,
    required this.summary,
  });
  final String title;
  final String type;
  final bool localOnly;
  final int? duration;
  final String language;
  final String narrator;
  final String edition;
  final String availability;
  final String summary;
}
