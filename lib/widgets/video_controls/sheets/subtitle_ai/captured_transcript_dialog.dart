part of '../subtitle_ai_sheet.dart';

/// Search and seek within the in-memory transcript captured from the watched
/// portion of the current decoded-PCM playback timeline.
class _CapturedTranscriptDialog extends StatefulWidget {
  const _CapturedTranscriptDialog({required this.player, required this.service, this.captureSummary});

  final Player player;
  final SubtitlePlaybackTranscriptionService service;
  final String? captureSummary;

  @override
  State<_CapturedTranscriptDialog> createState() => _CapturedTranscriptDialogState();
}

class _CapturedTranscriptDialogState extends State<_CapturedTranscriptDialog> {
  final TextEditingController _searchController = TextEditingController();
  bool _hideFutureDialogue = false;
  List<SubtitleCue>? _cachedSource;
  List<SubtitleCue> _filteredCues = const <SubtitleCue>[];
  String _cachedQuery = '';
  int _cachedVisibleCount = -1;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  int _visibleCueCount(List<SubtitleCue> cues, int positionMs) {
    var low = 0;
    var high = cues.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (cues[middle].startMs <= positionMs) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  List<SubtitleCue> _filterCues(List<SubtitleCue> cues, int visibleCount) {
    final query = _searchController.text.trim().toLowerCase();
    if (identical(_cachedSource, cues) && _cachedQuery == query && _cachedVisibleCount == visibleCount) {
      return _filteredCues;
    }
    final results = <SubtitleCue>[];
    for (var index = 0; index < visibleCount; index++) {
      final cue = cues[index];
      if (query.isEmpty || cue.text.replaceAll(RegExp(r'<[^>]*>|\{[^}]*\}'), ' ').toLowerCase().contains(query)) {
        results.add(cue);
      }
    }
    _cachedSource = cues;
    _cachedQuery = query;
    _cachedVisibleCount = visibleCount;
    _filteredCues = results;
    return results;
  }

  String _formatTime(int milliseconds) {
    final totalMs = milliseconds.clamp(0, SubtitleRetimer.maximumTimeMs).toInt();
    final hours = totalMs ~/ 3600000;
    final minutes = totalMs ~/ 60000 % 60;
    final seconds = totalMs ~/ 1000 % 60;
    final millis = totalMs % 1000;
    final clock =
        '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
    return hours == 0 ? clock : '${hours.toString().padLeft(2, '0')}:$clock';
  }

  Future<void> _seekToCue(SubtitleCue cue) async {
    try {
      final target = widget.service.playbackPositionForCue(cue);
      if (target.isNegative) {
        return;
      }
      await widget.player.seek(target);
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(context.t.subtitleAiUi.couldNotSeekToThisTranscriptCue)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final cues = widget.service.recentTranscript?.cues ?? const <SubtitleCue>[];
        return StreamBuilder<Duration>(
          stream: widget.player.streams.position,
          initialData: widget.player.currentPosition,
          builder: (context, snapshot) {
            final position = widget.service.captionPositionForPlayback(snapshot.data ?? widget.player.currentPosition);
            final visibleCount = _hideFutureDialogue ? _visibleCueCount(cues, position.inMilliseconds) : cues.length;
            final filtered = _filterCues(cues, visibleCount);
            final canSeek = widget.player.state.seekable && !widget.player.disposed;
            final height = (MediaQuery.of(context).size.height * 0.68).clamp(260.0, 560.0).toDouble();
            return AlertDialog(
              title: Text(context.t.subtitleAiUi.capturedTranscript),
              content: SizedBox(
                width: 620,
                height: height,
                child: Column(
                  children: [
                    Text(
                      widget.captureSummary ?? context.t.subtitleAiUi.onlyWatchedPortionsAreIncludedSelect_bb56a271,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _searchController,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        prefixIcon: const AppIcon(Symbols.search_rounded),
                        labelText: context.t.subtitleAiUi.searchTranscript,
                        border: const OutlineInputBorder(),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: context.t.subtitleAiUi.clearSearch,
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {});
                                },
                                icon: const AppIcon(Symbols.clear_rounded),
                              ),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(context.t.subtitleAiUi.hideFutureDialogue),
                      subtitle: Text(context.t.subtitleAiUi.showCuesFromTheCurrentPlayheadAndEarlier),
                      value: _hideFutureDialogue,
                      onChanged: (value) => setState(() => _hideFutureDialogue = value),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        context.t.subtitleAiUi.cueCountSummary(
                          visibleCount: filtered.length,
                          totalCount: cues.length,
                          seekingNote: canSeek ? '' : context.t.subtitleAiUi.seekingUnavailableNote,
                        ),
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text(
                                cues.isEmpty
                                    ? 'No speech cues yet. Keep capture running or stop it after speech is recognized.'
                                    : 'No cues match this view.',
                                textAlign: TextAlign.center,
                              ),
                            )
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final cue = filtered[index];
                                final current =
                                    position.inMilliseconds >= cue.startMs && position.inMilliseconds <= cue.endMs;
                                return ListTile(
                                  dense: true,
                                  selected: current,
                                  enabled: canSeek,
                                  leading: Text(
                                    _formatTime(cue.startMs),
                                    style: Theme.of(context).textTheme.labelSmall,
                                  ),
                                  title: Text(cue.text, maxLines: 3, overflow: TextOverflow.ellipsis),
                                  onTap: canSeek ? () => unawaited(_seekToCue(cue)) : null,
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.common.close))],
            );
          },
        );
      },
    );
  }
}
