import 'dart:math' as math;

/// A two-anchor fit for subtitle tracks whose timing drifts over the runtime.
///
/// mpv applies subtitle timestamps as `sourceTime * timestampMultiplier + delay`.
/// Given two subtitle cue times and the playback times those cues should match,
/// this solves the linear correction without modifying the subtitle file.
final class SubtitleSyncCalibration {
  const SubtitleSyncCalibration({required this.timestampMultiplier, required this.delayMs});

  static const minimumAnchorSpanSeconds = 60.0;
  static const minimumTimestampMultiplier = 0.8;
  static const maximumTimestampMultiplier = 1.25;
  static const minimumDelayMs = -60000;
  static const maximumDelayMs = 60000;
  static const maximumTimeMs = 60 * 24 * 60 * 60 * 1000;

  final double timestampMultiplier;
  final int delayMs;

  factory SubtitleSyncCalibration.fromAnchors({
    required double subtitleTime1Seconds,
    required double playbackTime1Seconds,
    required double subtitleTime2Seconds,
    required double playbackTime2Seconds,
  }) {
    final values = [subtitleTime1Seconds, playbackTime1Seconds, subtitleTime2Seconds, playbackTime2Seconds];
    if (values.any((value) => !value.isFinite || value < 0)) {
      throw ArgumentError('Anchor times must be finite, non-negative values.');
    }

    final subtitleSpan = subtitleTime2Seconds - subtitleTime1Seconds;
    final playbackSpan = playbackTime2Seconds - playbackTime1Seconds;
    if (subtitleSpan < minimumAnchorSpanSeconds || playbackSpan < minimumAnchorSpanSeconds) {
      throw ArgumentError('Choose increasing anchors at least 60 seconds apart.');
    }

    final multiplier = playbackSpan / subtitleSpan;
    if (!multiplier.isFinite || multiplier < minimumTimestampMultiplier || multiplier > maximumTimestampMultiplier) {
      throw RangeError.value(
        multiplier,
        'timestampMultiplier',
        'Must be finite and between $minimumTimestampMultiplier and $maximumTimestampMultiplier',
      );
    }

    final delayMs = ((playbackTime1Seconds - multiplier * subtitleTime1Seconds) * 1000).round();
    if (delayMs < minimumDelayMs || delayMs > maximumDelayMs) {
      throw RangeError.range(delayMs, minimumDelayMs, maximumDelayMs, 'delayMs');
    }

    return SubtitleSyncCalibration(timestampMultiplier: multiplier, delayMs: delayMs);
  }
}

/// A manually selected cue and the matching position on the opened media part.
/// Cue IDs are content-addressed by [SubtitleRetimer] and survive cue reordering.
final class SubtitleSyncObservation {
  const SubtitleSyncObservation({
    required this.cueId,
    required this.subtitleTimeMs,
    required this.playbackTimeMs,
    this.startsNewSegmentBefore = false,
  });

  final String cueId;
  final int subtitleTimeMs;
  final int playbackTimeMs;
  final bool startsNewSegmentBefore;

  Map<String, Object> toJson() => {
    'cueId': cueId,
    'subtitleTimeMs': subtitleTimeMs,
    'playbackTimeMs': playbackTimeMs,
    if (startsNewSegmentBefore) 'startsNewSegmentBefore': true,
  };

  SubtitleSyncObservation copyWith({bool? startsNewSegmentBefore}) => SubtitleSyncObservation(
    cueId: cueId,
    subtitleTimeMs: subtitleTimeMs,
    playbackTimeMs: playbackTimeMs,
    startsNewSegmentBefore: startsNewSegmentBefore ?? this.startsNewSegmentBefore,
  );

  static SubtitleSyncObservation fromJson(Object? value) {
    if (value is! Map<String, dynamic>) throw const FormatException('Calibration observation is invalid.');
    final cueId = value['cueId'];
    final subtitleTimeMs = value['subtitleTimeMs'];
    final playbackTimeMs = value['playbackTimeMs'];
    final startsNewSegmentBefore = value['startsNewSegmentBefore'];
    if (cueId is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(cueId) ||
        subtitleTimeMs is! int ||
        playbackTimeMs is! int ||
        subtitleTimeMs < 0 ||
        playbackTimeMs < 0 ||
        subtitleTimeMs > SubtitleSyncCalibration.maximumTimeMs ||
        playbackTimeMs > SubtitleSyncCalibration.maximumTimeMs ||
        (startsNewSegmentBefore != null && startsNewSegmentBefore is! bool)) {
      throw const FormatException('Calibration observation is outside its supported bounds.');
    }
    return SubtitleSyncObservation(
      cueId: cueId,
      subtitleTimeMs: subtitleTimeMs,
      playbackTimeMs: playbackTimeMs,
      startsNewSegmentBefore: startsNewSegmentBefore == true,
    );
  }
}

/// A robust global affine fit plus residual diagnostics for manually chosen cues.
final class SubtitleSyncCalibrationFit {
  const SubtitleSyncCalibrationFit({
    required this.calibration,
    required this.observations,
    required this.residualsMs,
    required this.maximumAbsoluteResidualMs,
    required this.rmsResidualMs,
  });

  static const int maximumObservations = 12;
  static const int minimumAnchorSpanMs = 60000;
  static const double maximumResidualMs = 750;

  final SubtitleSyncCalibration calibration;
  final List<SubtitleSyncObservation> observations;
  final List<double> residualsMs;
  final double maximumAbsoluteResidualMs;
  final double rmsResidualMs;

  bool get isConsistent => maximumAbsoluteResidualMs <= maximumResidualMs;

  Map<String, Object> toJson() => {
    'rate': calibration.timestampMultiplier,
    'delayMs': calibration.delayMs,
    'maximumAbsoluteResidualMs': maximumAbsoluteResidualMs,
    'rmsResidualMs': rmsResidualMs,
    'observations': observations.map((value) => value.toJson()).toList(growable: false),
  };

  factory SubtitleSyncCalibrationFit.fromObservations(List<SubtitleSyncObservation> input) {
    if (input.length < 2 || input.length > maximumObservations) {
      throw const FormatException('Choose between two and twelve subtitle cue observations.');
    }
    final cueIds = <String>{};
    final observations = List<SubtitleSyncObservation>.of(input)
      ..sort((left, right) {
        final sourceOrder = left.subtitleTimeMs.compareTo(right.subtitleTimeMs);
        return sourceOrder != 0 ? sourceOrder : left.playbackTimeMs.compareTo(right.playbackTimeMs);
      });
    for (final observation in observations) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(observation.cueId) ||
          !cueIds.add(observation.cueId) ||
          observation.subtitleTimeMs < 0 ||
          observation.playbackTimeMs < 0 ||
          observation.subtitleTimeMs > SubtitleSyncCalibration.maximumTimeMs ||
          observation.playbackTimeMs > SubtitleSyncCalibration.maximumTimeMs) {
        throw const FormatException('Calibration observations must refer to distinct, valid cues and times.');
      }
    }
    for (var index = 1; index < observations.length; index++) {
      if (observations[index].subtitleTimeMs <= observations[index - 1].subtitleTimeMs ||
          observations[index].playbackTimeMs <= observations[index - 1].playbackTimeMs) {
        throw const FormatException('Choose cues and playback times in increasing order.');
      }
    }

    final slopes = <double>[];
    var segment = 0;
    final segmentIds = <int>[];
    for (final observation in observations) {
      if (observation.startsNewSegmentBefore) segment++;
      segmentIds.add(segment);
    }
    if (observations.first.startsNewSegmentBefore) {
      throw const FormatException('The first cue cannot start a new cut segment.');
    }
    for (var left = 0; left < observations.length; left++) {
      for (var right = left + 1; right < observations.length; right++) {
        if (segmentIds[left] != segmentIds[right]) continue;
        final sourceSpan = observations[right].subtitleTimeMs - observations[left].subtitleTimeMs;
        if (sourceSpan < minimumAnchorSpanMs) continue;
        final targetSpan = observations[right].playbackTimeMs - observations[left].playbackTimeMs;
        final slope = targetSpan / sourceSpan;
        if (slope.isFinite && slope > 0) slopes.add(slope);
      }
    }
    if (slopes.isEmpty) throw const FormatException('Choose observations at least 60 seconds apart.');
    slopes.sort();
    final rate = _median(slopes);
    if (!rate.isFinite ||
        rate < SubtitleSyncCalibration.minimumTimestampMultiplier ||
        rate > SubtitleSyncCalibration.maximumTimestampMultiplier) {
      throw RangeError.value(
        rate,
        'timestampMultiplier',
        'Must be finite and between ${SubtitleSyncCalibration.minimumTimestampMultiplier} and ${SubtitleSyncCalibration.maximumTimestampMultiplier}',
      );
    }

    final intercepts =
        observations.map((value) => value.playbackTimeMs - rate * value.subtitleTimeMs).toList(growable: false)..sort();
    final delay = _median(intercepts).round();
    if (delay < SubtitleSyncCalibration.minimumDelayMs || delay > SubtitleSyncCalibration.maximumDelayMs) {
      throw RangeError.range(
        delay,
        SubtitleSyncCalibration.minimumDelayMs,
        SubtitleSyncCalibration.maximumDelayMs,
        'delayMs',
      );
    }
    final residuals = observations
        .map((value) => value.playbackTimeMs - (rate * value.subtitleTimeMs + delay))
        .toList(growable: false);
    final maximumAbsoluteResidual = residuals.map((value) => value.abs()).reduce((a, b) => a > b ? a : b);
    final rms = math.sqrt(residuals.fold<double>(0, (sum, value) => sum + value * value) / residuals.length);
    return SubtitleSyncCalibrationFit(
      calibration: SubtitleSyncCalibration(timestampMultiplier: rate, delayMs: delay),
      observations: List.unmodifiable(observations),
      residualsMs: List.unmodifiable(residuals),
      maximumAbsoluteResidualMs: maximumAbsoluteResidual,
      rmsResidualMs: rms,
    );
  }

  static double _median(List<double> sorted) {
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
  }
}

/// A bounded piecewise-linear mapping from the source subtitle clock to the
/// opened media-part clock. It is used only to create a derived export; the
/// native player accepts one affine rate/delay at a time.
final class SubtitlePiecewiseClockMap {
  SubtitlePiecewiseClockMap._(this.anchors, this.rate, this.segmentOffsets, this.segmentStarts);

  static const int maximumAnchors = SubtitleSyncCalibrationFit.maximumObservations;
  final List<SubtitleSyncObservation> anchors;
  final double rate;
  final List<double> segmentOffsets;
  final List<int> segmentStarts;

  bool crossesSegmentBoundary(int startMs, int endMs) =>
      segmentStarts.skip(1).any((boundary) => startMs < boundary && endMs >= boundary);

  factory SubtitlePiecewiseClockMap.fromObservations(List<SubtitleSyncObservation> input) {
    if (input.length < 2 || input.length > maximumAnchors) {
      throw const FormatException('A piecewise export needs between two and twelve cue anchors.');
    }
    final sorted = List<SubtitleSyncObservation>.of(input)
      ..sort((left, right) => left.subtitleTimeMs.compareTo(right.subtitleTimeMs));
    if (sorted.map((anchor) => anchor.cueId).toSet().length != sorted.length) {
      throw const FormatException('Piecewise anchors must refer to distinct subtitle cues.');
    }
    for (final anchor in sorted) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(anchor.cueId) ||
          anchor.subtitleTimeMs < 0 ||
          anchor.playbackTimeMs < 0 ||
          anchor.subtitleTimeMs > SubtitleSyncCalibration.maximumTimeMs ||
          anchor.playbackTimeMs > SubtitleSyncCalibration.maximumTimeMs) {
        throw const FormatException('Piecewise anchors must have stable cue IDs and bounded times.');
      }
    }
    if (sorted.first.startsNewSegmentBefore) {
      throw const FormatException('The first cue cannot start a new cut segment.');
    }
    for (var index = 1; index < sorted.length; index++) {
      if (sorted[index].subtitleTimeMs <= sorted[index - 1].subtitleTimeMs ||
          sorted[index].playbackTimeMs <= sorted[index - 1].playbackTimeMs) {
        throw const FormatException('Piecewise anchors must increase in both subtitle and playback time.');
      }
    }
    final groups = <List<SubtitleSyncObservation>>[];
    for (final anchor in sorted) {
      if (groups.isEmpty || anchor.startsNewSegmentBefore) groups.add(<SubtitleSyncObservation>[]);
      groups.last.add(anchor);
    }
    final slopes = <double>[];
    for (final group in groups) {
      for (var left = 0; left < group.length; left++) {
        for (var right = left + 1; right < group.length; right++) {
          final sourceSpan = group[right].subtitleTimeMs - group[left].subtitleTimeMs;
          if (sourceSpan < SubtitleSyncCalibrationFit.minimumAnchorSpanMs) continue;
          final targetSpan = group[right].playbackTimeMs - group[left].playbackTimeMs;
          final slope = targetSpan / sourceSpan;
          if (slope.isFinite && slope > 0) slopes.add(slope);
        }
      }
    }
    if (slopes.isEmpty) {
      throw const FormatException('At least two anchors in one cut segment must be 60 seconds apart to estimate rate.');
    }
    slopes.sort();
    final rate = SubtitleSyncCalibrationFit._median(slopes);
    if (!rate.isFinite ||
        rate < SubtitleSyncCalibration.minimumTimestampMultiplier ||
        rate > SubtitleSyncCalibration.maximumTimestampMultiplier) {
      throw const FormatException('Piecewise rate must stay between 80% and 125% speed.');
    }
    final offsets = <double>[];
    final starts = <int>[];
    for (final group in groups) {
      starts.add(group.first.subtitleTimeMs);
      final intercepts =
          group.map((anchor) => anchor.playbackTimeMs - rate * anchor.subtitleTimeMs).toList(growable: false)..sort();
      final offset = SubtitleSyncCalibrationFit._median(intercepts);
      final maximumResidual = group
          .map((anchor) => (anchor.playbackTimeMs - (rate * anchor.subtitleTimeMs + offset)).abs())
          .fold<double>(0, (maximum, residual) => residual > maximum ? residual : maximum);
      if (maximumResidual > SubtitleSyncCalibrationFit.maximumResidualMs) {
        throw const FormatException('Anchors within one cut segment differ by more than 750 ms.');
      }
      offsets.add(offset);
    }
    return SubtitlePiecewiseClockMap._(
      List.unmodifiable(sorted),
      rate,
      List.unmodifiable(offsets),
      List.unmodifiable(starts),
    );
  }

  int map(int sourceMs) {
    if (sourceMs < 0 || sourceMs > SubtitleSyncCalibration.maximumTimeMs) {
      throw RangeError.range(sourceMs, 0, SubtitleSyncCalibration.maximumTimeMs, 'sourceMs');
    }
    var segment = 0;
    while (segment < segmentStarts.length - 1 && sourceMs >= segmentStarts[segment + 1]) {
      segment++;
    }
    final mapped = (sourceMs * rate + segmentOffsets[segment]).round();
    if (mapped < -SubtitleSyncCalibration.maximumTimeMs || mapped > SubtitleSyncCalibration.maximumTimeMs) {
      throw const FormatException('Piecewise subtitle time is outside the supported range.');
    }
    return mapped;
  }
}
