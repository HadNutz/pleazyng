import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/subtitle_retimer.dart';
import '../../../services/subtitle_text_codec.dart';

final class SubtitleEncodingPreview {
  const SubtitleEncodingPreview({required this.cues, required this.encoding});

  final List<SubtitleCue> cues;
  final String encoding;
}

/// Lets the viewer explicitly choose and review subtitle text decoding.
/// The original bytes are read-only and are never rewritten.
class SubtitleEncodingPreviewDialog extends StatefulWidget {
  const SubtitleEncodingPreviewDialog({
    super.key,
    required this.sourceBytes,
    required this.extension,
    required this.fileName,
  });

  final List<int> sourceBytes;
  final String extension;
  final String fileName;

  @override
  State<SubtitleEncodingPreviewDialog> createState() => _SubtitleEncodingPreviewDialogState();
}

enum _SubtitleEncodingPreviewError { noCues, decodeFailed, invalidSubtitle }

class _SubtitleEncodingPreviewDialogState extends State<SubtitleEncodingPreviewDialog> {
  String _encoding = SubtitleTextCodec.defaultEncoding;
  List<SubtitleCue>? _cues;
  _SubtitleEncodingPreviewError? _error;

  @override
  void initState() {
    super.initState();
    _decodePreview();
  }

  void _decodePreview() {
    final String decoded;
    try {
      decoded = SubtitleTextCodec.decode(widget.sourceBytes, encoding: _encoding);
    } on Object {
      _cues = null;
      _error = _SubtitleEncodingPreviewError.decodeFailed;
      return;
    }

    final List<SubtitleCue> cues;
    try {
      cues = SubtitleRetimer.parseCues(sourceBytes: utf8.encode(decoded), extension: widget.extension);
    } on Object {
      _cues = null;
      _error = _SubtitleEncodingPreviewError.invalidSubtitle;
      return;
    }
    if (cues.isEmpty) {
      _cues = null;
      _error = _SubtitleEncodingPreviewError.noCues;
      return;
    }
    _cues = List<SubtitleCue>.unmodifiable(cues);
    _error = null;
  }

  @override
  Widget build(BuildContext context) {
    final cues = _cues;
    final sampleIndexes = <int>{
      0,
      1,
      cues == null ? -1 : cues.length ~/ 2,
      (cues?.length ?? 0) - 1,
    }.where((index) => cues != null && index >= 0 && index < cues.length).toList(growable: false)..sort();
    final screenSize = MediaQuery.sizeOf(context);
    final maxHeight = (screenSize.height - 220).clamp(160.0, 520.0).toDouble();
    final maxWidth = (screenSize.width - 64).clamp(200.0, 560.0).toDouble();

    return AlertDialog(
      title: Text(context.t.subtitleAiUi.subtitleEncodingPreviewTitle),
      content: SizedBox(
        width: maxWidth,
        height: maxHeight,
        child: ListView(
          children: [
            Text(widget.fileName),
            const SizedBox(height: 8),
            Text(context.t.subtitleAiUi.subtitleEncodingPreviewDescription),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('subtitle-encoding-preview-select'),
              initialValue: _encoding,
              isExpanded: true,
              decoration: InputDecoration(labelText: context.t.subtitleAiUi.subtitleEncodingSourceLabel),
              items: SubtitleTextCodec.encodings.entries
                  .map((entry) => DropdownMenuItem<String>(value: entry.key, child: Text(entry.value)))
                  .toList(growable: false),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _encoding = value;
                  _decodePreview();
                });
              },
            ),
            const SizedBox(height: 12),
            if (_error case final error?)
              Text(switch (error) {
                _SubtitleEncodingPreviewError.noCues => context.t.subtitleAiUi.subtitleEncodingNoCues,
                _SubtitleEncodingPreviewError.decodeFailed => context.t.subtitleAiUi.subtitleEncodingDecodeFailed,
                _SubtitleEncodingPreviewError.invalidSubtitle => context.t.romm.invalidFile,
              }, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (cues case final parsed?) ...[
              Text(context.t.subtitleAiUi.subtitleEncodingPreviewCueCount(count: parsed.length)),
              for (final index in sampleIndexes) ...[
                const Divider(height: 18),
                Text('${_formatTime(parsed[index].startMs)} → ${_formatTime(parsed[index].endMs)}'),
                const SizedBox(height: 4),
                SelectableText(parsed[index].text),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.common.cancel)),
        FilledButton(
          onPressed: cues == null
              ? null
              : () => Navigator.of(context).pop(SubtitleEncodingPreview(cues: cues, encoding: _encoding)),
          child: Text(context.t.subtitleAiUi.subtitleEncodingUsePreview),
        ),
      ],
    );
  }
}

String _formatTime(int milliseconds) {
  final hours = milliseconds ~/ 3600000;
  final minutes = (milliseconds ~/ 60000) % 60;
  final seconds = (milliseconds ~/ 1000) % 60;
  final millis = milliseconds % 1000;
  return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')},${millis.toString().padLeft(3, '0')}';
}
