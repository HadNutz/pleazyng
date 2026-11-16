import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/subtitle_retimer.dart';
import 'package:plezy/services/subtitle_sync_service.dart';

void main() {
  test('recovers a known fixture offset and leaves source cues unchanged', () {
    final target = _readCues('offset-target.srt');
    final reference = _readCues('offset-reference.srt');
    final sourceSnapshot = target.map(_snapshotCue).toList();

    final result = SubtitleSyncService.synchronizeAgainstReference(
      subtitleCues: target,
      referenceCues: reference,
      mediaDurationMs: 180000,
      repairCuts: false,
    );

    expect(result.globalOffsetMs, 2000);
    expect(result.appliedRate, closeTo(1, 0.000001));
    expect(result.matchedCueCount, 5);
    expect(result.cues.map((cue) => cue.startMs).toList(), [12000, 42000, 72000, 102000, 132000]);
    expect(result.cues.map((cue) => cue.id), target.map((cue) => cue.id));
    expect(result.cues.map((cue) => cue.text), target.map((cue) => cue.text));
    expect(target.map(_snapshotCue).toList(), sourceSnapshot);
  });

  test('recovers gradual drift from fixture dialogue anchors', () {
    final target = _readCues('drift-target.srt');
    final reference = _readCues('drift-reference.srt');

    final result = SubtitleSyncService.synchronize(
      subtitleCues: target,
      speechCues: reference,
      mediaDurationMs: 180000,
      repairCuts: false,
    );

    expect(result.appliedRate, closeTo(1.02, 0.000001));
    expect(result.globalOffsetMs, 1500);
    expect(result.matchedCueCount, 5);
    expect(result.cues.map((cue) => cue.startMs).toList(), [11700, 42300, 72900, 103500, 134100]);
    expect(result.cues.map((cue) => cue.endMs).toList(), [13740, 44340, 74940, 105540, 136140]);
  });

  test('repairs an edited-cut offset jump without fitting one rate across it', () {
    final target = _readCues('cut-target.srt');
    final reference = _readCues('cut-reference.srt');

    final result = SubtitleSyncService.synchronize(
      subtitleCues: target,
      speechCues: reference,
      mediaDurationMs: 120000,
      repairCuts: true,
    );

    expect(result.appliedRate, 1);
    expect(result.discontinuityCount, 1);
    expect(result.matchedCueCount, 6);
    expect(result.cues.map((cue) => cue.startMs).toList(), [12000, 22000, 32000, 45000, 55000, 65000]);
  });

  test('repeated text does not create a false cut when two references are plausible', () {
    final target = _readCues('repeated-target.srt');
    final reference = _readCues('repeated-reference.srt');

    final result = SubtitleSyncService.synchronize(
      subtitleCues: target,
      speechCues: reference,
      mediaDurationMs: 180000,
      repairCuts: true,
    );

    expect(result.matchedCueCount, 3);
    expect(result.discontinuityCount, 0);
    expect(result.cues.map((cue) => cue.startMs).toList(), [12000, 42000, 72000, 102000]);
  });

  test('refuses alignment when fixture texts have no reliable matches', () {
    final target = _readCues('low-confidence-target.srt');
    final reference = _readCues('low-confidence-reference.srt');

    expect(
      () => SubtitleSyncService.synchronize(
        subtitleCues: target,
        speechCues: reference,
        mediaDurationMs: 120000,
        repairCuts: false,
      ),
      throwsFormatException,
    );
  });
}

List<SubtitleCue> _readCues(String name) => SubtitleRetimer.parseCues(
  sourceBytes: File('test/fixtures/subtitle_sync/$name').readAsBytesSync(),
  extension: '.srt',
);

String _snapshotCue(SubtitleCue cue) => '${cue.id}|${cue.index}|${cue.startMs}|${cue.endMs}|${cue.text}';
