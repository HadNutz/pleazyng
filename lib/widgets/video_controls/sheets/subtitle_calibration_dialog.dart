import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/widgets/app_icon.dart';

import '../../../i18n/strings.g.dart';
import '../../../mpv/mpv.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_calibration_export.dart';
import '../../../services/subtitle_calibration_history.dart';
import '../../../services/subtitle_calibration_source.dart';
import '../../../services/subtitle_retimer.dart';
import '../../../services/subtitle_sync_calibration.dart';

final class SubtitleCalibrationDialog extends StatefulWidget {
  const SubtitleCalibrationDialog({
    super.key,
    required this.player,
    required this.request,
    required this.previousRate,
    required this.previousDelayMs,
    required this.canApplyNative,
    required this.onPreview,
    required this.onSave,
  });

  final Player player;
  final SubtitleCalibrationRequest request;
  final double previousRate;
  final int previousDelayMs;
  final bool canApplyNative;
  final Future<bool> Function(SubtitleSyncCalibrationFit fit) onPreview;
  final Future<bool> Function(SubtitleSyncCalibrationFit fit) onSave;

  @override
  State<SubtitleCalibrationDialog> createState() => _SubtitleCalibrationDialogState();
}

class _SubtitleCalibrationDialogState extends State<SubtitleCalibrationDialog> {
  List<int>? _sourceBytes;
  List<SubtitleCue> _cues = const [];
  SubtitleCalibrationIdentity? _identity;
  List<SubtitleCalibrationRecord> _history = const [];
  final List<SubtitleSyncObservation> _observations = [];
  bool _loading = true;
  bool _working = false;
  bool _previewActive = false;
  String? _failure;
  String? _status;
  SubtitleSyncCalibrationFit? _fit;
  String? _fitFailure;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final extension = widget.request.extension;
      if (!const {'.srt', '.vtt', '.ass', '.ssa'}.contains(extension)) {
        throw const FormatException('Unsupported subtitle format.');
      }
      if (!await widget.request.isCurrent()) throw const FormatException('Subtitle track changed.');
      final bytes = await SubtitleCalibrationSourceReader.read(widget.request.uri);
      if (!await widget.request.isCurrent()) throw const FormatException('Subtitle track changed.');
      final cues = SubtitleRetimer.parseCues(sourceBytes: bytes, extension: extension);
      final identity = widget.request.identityFor(bytes);
      final history = await SubtitleCalibrationHistoryService.load(identity);
      if (!mounted) return;
      setState(() {
        _sourceBytes = bytes;
        _cues = cues;
        _identity = identity;
        _history = history;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = context.t.videoControls.subtitleLoadFailed;
      });
    }
  }

  void _recompute() {
    _fit = null;
    _fitFailure = null;
    if (_observations.length < 2) return;
    try {
      _fit = SubtitleSyncCalibrationFit.fromObservations(_observations);
    } on Object {
      _fitFailure = context.t.videoSettings.subtitleDriftInvalidAnchors;
    }
  }

  int? _openedPartPositionMs() {
    final sourcePosition = widget.player.state.position.inMilliseconds - widget.player.timelineOffset.inMilliseconds;
    return sourcePosition < 0 ? null : sourcePosition;
  }

  Future<void> _verifySelectedBytes(SubtitleCalibrationIdentity identity) async {
    final currentBytes = await SubtitleCalibrationSourceReader.read(widget.request.uri);
    if (SubtitleCalibrationIdentity.digestBytes(currentBytes) != identity.sourceBytesDigest) {
      throw const FormatException('Subtitle bytes changed.');
    }
    if (!await widget.request.isCurrent()) {
      throw const FormatException('Subtitle track changed.');
    }
  }

  Future<void> _pickCue() async {
    if (!await widget.request.isCurrent()) {
      setState(() => _failure = context.t.videoSettings.subtitleCueUnavailable);
      return;
    }
    if (!mounted) return;
    final observation = await showModalBottomSheet<SubtitleSyncObservation>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SubtitleCuePickerSheet(
        cues: _cues,
        onCapture: () => _openedPartPositionMs(),
        excludedIds: _observations.map((value) => value.cueId).toSet(),
      ),
    );
    if (!mounted || observation == null) return;
    if (!await widget.request.isCurrent()) {
      if (!mounted) return;
      setState(() => _failure = context.t.videoSettings.subtitleCueUnavailable);
      return;
    }
    if (observation.playbackTimeMs < 0) {
      setState(() => _failure = context.t.videoSettings.subtitleCueUnavailable);
      return;
    }
    if (_observations.length >= SubtitleSyncCalibrationFit.maximumObservations) {
      setState(() => _failure = context.t.videoSettings.subtitleDriftInvalidAnchors);
      return;
    }
    if (_observations.any((value) => value.cueId == observation.cueId)) {
      setState(() => _failure = context.t.videoSettings.subtitleDriftInvalidAnchors);
      return;
    }
    final next = observation;
    if (_observations.isNotEmpty &&
        (next.subtitleTimeMs <= _observations.last.subtitleTimeMs ||
            next.playbackTimeMs <= _observations.last.playbackTimeMs)) {
      setState(() => _failure = context.t.videoSettings.subtitleDriftInvalidAnchors);
      return;
    }
    setState(() {
      _failure = null;
      _status = null;
      _observations.add(next);
      _recompute();
    });
  }

  Future<void> _preview() async {
    final fit = _fit;
    final identity = _identity;
    if (fit == null || !fit.isConsistent || !widget.canApplyNative) return;
    if (identity == null) return;
    setState(() {
      _working = true;
      _failure = null;
      _status = null;
    });
    try {
      await _verifySelectedBytes(identity);
    } on Object {
      if (!mounted) return;
      setState(() {
        _failure = context.t.videoSettings.subtitleCueUnavailable;
        _working = false;
      });
      return;
    }
    final applied = await widget.onPreview(fit);
    if (!mounted) return;
    setState(() {
      _working = false;
      _previewActive = applied;
      if (!applied) _failure = context.t.videoSettings.subtitleDriftPreviewFailed;
    });
  }

  Future<void> _saveNative() async {
    final fit = _fit;
    final identity = _identity;
    if (fit == null || !fit.isConsistent || !widget.canApplyNative) return;
    if (identity == null) return;
    setState(() {
      _working = true;
      _failure = null;
      _status = null;
    });
    try {
      await _verifySelectedBytes(identity);
    } on Object {
      if (!mounted) return;
      setState(() {
        _working = false;
        _failure = context.t.videoSettings.subtitleCueUnavailable;
      });
      return;
    }
    final saved = await widget.onSave(fit);
    if (!mounted) return;
    if (!saved) {
      setState(() {
        _working = false;
        _failure = context.t.videoSettings.subtitleDriftPreviewFailed;
      });
      return;
    }
    try {
      await SubtitleCalibrationHistoryService.save(
        identity: identity,
        observations: List.unmodifiable(_observations),
        fit: fit,
        previousRate: widget.previousRate,
        previousDelayMs: widget.previousDelayMs,
      );
      final history = await SubtitleCalibrationHistoryService.load(identity);
      if (!mounted) return;
      setState(() {
        _history = history;
        _working = false;
        _previewActive = false;
        _status = null;
      });
      Navigator.of(context).pop(fit);
    } on Object {
      if (!mounted) return;
      setState(() {
        _working = false;
        _previewActive = false;
        _status = context.t.common.error;
      });
    }
  }

  Future<void> _exportPiecewise() async {
    final bytes = _sourceBytes;
    final identity = _identity;
    if (bytes == null || identity == null || _observations.length < 2 || _working) return;
    final exportTitle = context.t.videoSettings.subtitleExport;
    final extension = widget.request.extension;
    if (extension != '.srt' && extension != '.vtt') {
      setState(() => _failure = context.t.videoSettings.subtitleExportFailed);
      return;
    }
    SubtitlePiecewiseClockMap mapping;
    SubtitleRetimingResult preview;
    try {
      mapping = SubtitlePiecewiseClockMap.fromObservations(_observations);
      preview = SubtitleRetimer.retimePiecewise(sourceBytes: bytes, extension: extension, mapping: mapping);
    } on Object {
      setState(() => _failure = context.t.videoSettings.subtitleExportFailed);
      return;
    }
    if (!await widget.request.isCurrent()) {
      if (!mounted) return;
      setState(() => _failure = context.t.videoSettings.subtitleCueUnavailable);
      return;
    }
    if (preview.clippedCueCount > 0) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.t.videoSettings.subtitleExport),
          content: Text(context.t.videoSettings.subtitleExportClipped),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.common.cancel)),
            TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(context.t.common.confirm)),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      _working = true;
      _failure = null;
      _status = null;
    });
    try {
      // Re-read the selected bytes before export. This detects a server or
      // local-file replacement during calibration; the stored digest does not
      // claim that a player-side cache had loaded these same bytes.
      final currentBytes = await SubtitleCalibrationSourceReader.read(widget.request.uri);
      if (SubtitleCalibrationIdentity.digestBytes(currentBytes) != identity.sourceBytesDigest) {
        throw const FormatException('Subtitle bytes changed.');
      }
      if (!await widget.request.isCurrent()) {
        throw const FormatException('Subtitle track changed.');
      }
      final archive = SubtitleCalibrationExport.create(
        originalBytes: bytes,
        fileName: widget.request.displayName,
        extension: extension,
        identity: identity,
        mapping: mapping,
        observations: _observations,
        fit: _fit,
        previousRate: widget.previousRate,
        previousDelayMs: widget.previousDelayMs,
      );
      final path = await FilePickerService.instance.saveFile(
        dialogTitle: exportTitle,
        fileName: 'subtitle-calibration.zip',
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        bytes: archive,
      );
      if (!mounted) return;
      if (path == null) {
        setState(() => _working = false);
        return;
      }
      try {
        await SubtitleCalibrationHistoryService.save(
          identity: identity,
          observations: List.unmodifiable(_observations),
          fit: _fit,
          previousRate: widget.previousRate,
          previousDelayMs: widget.previousDelayMs,
        );
        final history = await SubtitleCalibrationHistoryService.load(identity);
        if (!mounted) return;
        setState(() {
          _history = history;
          _working = false;
          _status = context.t.videoSettings.subtitleExportSuccess;
        });
      } on Object {
        if (!mounted) return;
        setState(() {
          _working = false;
          _status = context.t.common.error;
        });
      }
    } on Object {
      if (!mounted) return;
      setState(() {
        _working = false;
        _failure = context.t.videoSettings.subtitleExportFailed;
      });
    }
  }

  Future<void> _loadHistory(SubtitleCalibrationRecord record) async {
    final cueStartsById = {for (final cue in _cues) cue.id: cue.startMs};
    if (record.observations.any((observation) => cueStartsById[observation.cueId] != observation.subtitleTimeMs)) {
      setState(() {
        _failure = context.t.videoSettings.subtitleCueUnavailable;
        _status = null;
      });
      return;
    }
    setState(() {
      _observations
        ..clear()
        ..addAll(record.observations);
      _failure = null;
      _status = null;
      _recompute();
    });
  }

  Widget _buildCueAnchors() {
    if (_observations.isEmpty) return const SizedBox.shrink();
    final positions = {for (var index = 0; index < _cues.length; index++) _cues[index].id: index};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < _observations.length; index++)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(radius: 14, child: Text('${index + 1}')),
            title: Text(
              _cues[positions[_observations[index].cueId] ?? 0].text.replaceAll('\n', ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${_time(_observations[index].subtitleTimeMs)} → ${_time(_observations[index].playbackTimeMs)}'
              '${_observations[index].startsNewSegmentBefore ? ' · ↳' : ''}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: _observations[index].startsNewSegmentBefore
                      ? context.t.common.delete
                      : context.t.videoSettings.subtitleDriftCalibration,
                  onPressed: _working || index == 0
                      ? null
                      : () => setState(() {
                          _observations[index] = _observations[index].copyWith(
                            startsNewSegmentBefore: !_observations[index].startsNewSegmentBefore,
                          );
                          _recompute();
                        }),
                  icon: AppIcon(
                    _observations[index].startsNewSegmentBefore
                        ? Symbols.call_split_rounded
                        : Symbols.horizontal_rule_rounded,
                  ),
                ),
                IconButton(
                  tooltip: context.t.common.delete,
                  onPressed: _working
                      ? null
                      : () => setState(() {
                          _observations.removeAt(index);
                          _recompute();
                        }),
                  icon: const AppIcon(Symbols.close_rounded),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _time(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    final hours = seconds ~/ 3600;
    final minutes = (seconds ~/ 60) % 60;
    final remainder = seconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final fit = _fit;
    final piecewiseAvailable =
        _observations.length >= 2 &&
        (_tryPiecewise() != null) &&
        (widget.request.extension == '.srt' || widget.request.extension == '.vtt');
    return AlertDialog(
      title: Text(context.t.videoSettings.subtitleDriftCalibration),
      content: SizedBox(
        width: 620,
        child: _loading
            ? const SizedBox(height: 180, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.request.displayName),
                    const SizedBox(height: 8),
                    Text(
                      '${context.t.videoSettings.subtitleSync}: ${widget.previousRate.toStringAsFixed(4)}× · ${widget.previousDelayMs} ms',
                    ),
                    const SizedBox(height: 8),
                    Text(context.t.videoSettings.subtitleDriftCalibrationHelp),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _working || _observations.length >= SubtitleSyncCalibrationFit.maximumObservations
                          ? null
                          : _pickCue,
                      icon: const AppIcon(Symbols.add_rounded),
                      label: Text(context.t.videoSettings.subtitleCueTools),
                    ),
                    _buildCueAnchors(),
                    if (fit != null) ...[
                      const Divider(),
                      Text(
                        '${fit.calibration.timestampMultiplier.toStringAsFixed(6)}× · ${fit.calibration.delayMs} ms · ${fit.maximumAbsoluteResidualMs.toStringAsFixed(0)} ms',
                      ),
                      if (!fit.isConsistent) Text(context.t.videoSettings.subtitleDriftInvalidAnchors),
                    ] else if (_fitFailure != null && _observations.length >= 2) ...[
                      const Divider(),
                      Text(_fitFailure!),
                    ],
                    if (_observations.length >= 2 &&
                        _tryPiecewise() == null &&
                        (widget.request.extension == '.srt' || widget.request.extension == '.vtt'))
                      Text(context.t.videoSettings.subtitleDriftCalibrationHelp),
                    if (_previewActive) Text(context.t.videoSettings.subtitleDriftPreviewActive),
                    for (final record in _history)
                      TextButton.icon(
                        onPressed: _working ? null : () => _loadHistory(record),
                        icon: const AppIcon(Symbols.history_rounded),
                        label: Text('${record.createdAt.toLocal()} · ${record.observations.length}'),
                      ),
                    if (_failure != null) ...[
                      const SizedBox(height: 8),
                      Text(_failure!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                    if (_status != null) ...[const SizedBox(height: 8), Text(_status!)],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.of(context).pop(),
          child: Text(context.t.common.cancel),
        ),
        if (!_loading && widget.canApplyNative && fit?.isConsistent == true)
          TextButton(onPressed: _working ? null : _preview, child: Text(context.t.common.preview)),
        if (!_loading && widget.canApplyNative && fit?.isConsistent == true)
          TextButton(onPressed: _working ? null : _saveNative, child: Text(context.t.common.save)),
        if (!_loading)
          TextButton(
            onPressed: _working || !piecewiseAvailable ? null : _exportPiecewise,
            child: Text(context.t.videoSettings.subtitleExport),
          ),
      ],
    );
  }

  SubtitlePiecewiseClockMap? _tryPiecewise() {
    try {
      return SubtitlePiecewiseClockMap.fromObservations(_observations);
    } on Object {
      return null;
    }
  }
}

class SubtitleCuePickerSheet extends StatefulWidget {
  const SubtitleCuePickerSheet({super.key, required this.cues, required this.onCapture, required this.excludedIds});

  final List<SubtitleCue> cues;
  final int? Function() onCapture;
  final Set<String> excludedIds;

  @override
  State<SubtitleCuePickerSheet> createState() => _SubtitleCuePickerSheetState();
}

class _SubtitleCuePickerSheetState extends State<SubtitleCuePickerSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final matches = query.isEmpty
        ? widget.cues
        : widget.cues.where((cue) => cue.text.toLowerCase().contains(query)).toList(growable: false);
    return SafeArea(
      child: FractionallySizedBox(
        heightFactor: .82,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _search,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: context.t.common.search,
                  prefixIcon: const AppIcon(Symbols.search_rounded),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: matches.length,
                itemBuilder: (context, index) {
                  final cue = matches[index];
                  final excluded = widget.excludedIds.contains(cue.id);
                  final text = cue.text.replaceAll('\n', ' ');
                  final preview = text.length <= 700 ? text : '${text.substring(0, 700)}…';
                  return ListTile(
                    enabled: !excluded,
                    title: Text(preview, maxLines: 3, overflow: TextOverflow.ellipsis),
                    subtitle: Text(_time(cue.startMs)),
                    onTap: excluded
                        ? null
                        : () {
                            final playbackMs = widget.onCapture();
                            if (playbackMs == null) {
                              ScaffoldMessenger.maybeOf(
                                context,
                              )?.showSnackBar(SnackBar(content: Text(context.t.videoSettings.subtitleCueUnavailable)));
                              return;
                            }
                            Navigator.of(context).pop(
                              SubtitleSyncObservation(
                                cueId: cue.id,
                                subtitleTimeMs: cue.startMs,
                                playbackTimeMs: playbackMs,
                              ),
                            );
                          },
                  );
                },
              ),
            ),
            Padding(padding: const EdgeInsets.all(12), child: Text(context.t.videoSettings.subtitleUsePlaybackTime)),
          ],
        ),
      ),
    );
  }

  String _time(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    final hours = seconds ~/ 3600;
    final minutes = (seconds ~/ 60) % 60;
    final remainder = seconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
  }
}
