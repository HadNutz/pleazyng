import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'subtitle_calibration_history.dart';
import 'subtitle_retimer.dart';
import 'subtitle_sync_calibration.dart';

/// Builds a bounded archive with the original sidecar byte-for-byte and a
/// separately corrected SRT/WebVTT copy. It never edits or attaches a source.
abstract final class SubtitleCalibrationExport {
  static const int maximumArchiveBytes = 12 * 1024 * 1024;

  static Uint8List create({
    required List<int> originalBytes,
    required String fileName,
    required String extension,
    required SubtitleCalibrationIdentity identity,
    required SubtitlePiecewiseClockMap mapping,
    required List<SubtitleSyncObservation> observations,
    required SubtitleSyncCalibrationFit? fit,
    required double previousRate,
    required int previousDelayMs,
  }) {
    identity.validate();
    if (originalBytes.isEmpty ||
        originalBytes.length > SubtitleRetimer.maximumInputBytes ||
        SubtitleCalibrationIdentity.digestBytes(originalBytes) != identity.sourceBytesDigest) {
      throw const FormatException('The selected sidecar bytes no longer match this calibration.');
    }
    final cueById = {
      for (final cue in SubtitleRetimer.parseCues(sourceBytes: originalBytes, extension: extension)) cue.id: cue,
    };
    if (observations.length < 2 || observations.length > SubtitleSyncCalibrationFit.maximumObservations) {
      throw const FormatException('A piecewise calibration with two to twelve observations is required.');
    }
    if (observations.any((observation) => cueById[observation.cueId]?.startMs != observation.subtitleTimeMs)) {
      throw const FormatException('An export anchor does not match a cue in the exact selected sidecar.');
    }
    final validatedMapping = SubtitlePiecewiseClockMap.fromObservations(observations);
    if (validatedMapping.anchors.length != mapping.anchors.length ||
        validatedMapping.anchors.asMap().entries.any(
          (entry) =>
              entry.value.cueId != mapping.anchors[entry.key].cueId ||
              entry.value.subtitleTimeMs != mapping.anchors[entry.key].subtitleTimeMs ||
              entry.value.playbackTimeMs != mapping.anchors[entry.key].playbackTimeMs ||
              entry.value.startsNewSegmentBefore != mapping.anchors[entry.key].startsNewSegmentBefore,
        ) ||
        (fit != null &&
            (fit.observations.length != mapping.anchors.length ||
                fit.observations.asMap().entries.any(
                  (entry) =>
                      entry.value.cueId != mapping.anchors[entry.key].cueId ||
                      entry.value.subtitleTimeMs != mapping.anchors[entry.key].subtitleTimeMs ||
                      entry.value.playbackTimeMs != mapping.anchors[entry.key].playbackTimeMs ||
                      entry.value.startsNewSegmentBefore != mapping.anchors[entry.key].startsNewSegmentBefore,
                ))) ||
        !previousRate.isFinite ||
        previousRate < SubtitleSyncCalibration.minimumTimestampMultiplier ||
        previousRate > SubtitleSyncCalibration.maximumTimestampMultiplier ||
        previousDelayMs < SubtitleSyncCalibration.minimumDelayMs ||
        previousDelayMs > SubtitleSyncCalibration.maximumDelayMs) {
      throw const FormatException('Piecewise export inputs do not match their validated timing scope.');
    }
    final corrected = SubtitleRetimer.retimePiecewise(
      sourceBytes: originalBytes,
      extension: extension,
      mapping: mapping,
    );
    final safeName = _safeFileName(fileName, extension);
    final original = Uint8List.fromList(originalBytes);
    final derived = Uint8List.fromList(corrected.bytes);
    final files = <String, Uint8List>{'original/$safeName': original, 'corrected/$safeName': derived};
    final manifest = <String, Object?>{
      'schema': 'plezyng.subtitle-calibration-export.v1',
      'scope': identity.toSafeJson(),
      'originalSha256': sha256.convert(original).toString(),
      'correctedSha256': sha256.convert(derived).toString(),
      'originalPath': 'original/$safeName',
      'correctedPath': 'corrected/$safeName',
      'sourceClock': 'subtitle-file-clock',
      'targetClock': 'opened-media-part-ms',
      'partOffsetMs': identity.partOffsetMs,
      'mapping': 'shared-rate-piecewise-offsets-with-explicit-cut-boundaries',
      'anchors': observations.map((observation) => observation.toJson()).toList(growable: false),
      if (fit != null) 'nativeAffineFit': fit.toJson(),
      'previousPlayerSettings': {'subtitleRate': previousRate, 'subtitleDelayMs': previousDelayMs},
      'retimedCueCount': corrected.retimedCueCount,
      'clippedBeforeZeroCueCount': corrected.clippedCueCount,
      'originalUnchanged': true,
      'serverContentLimit':
          'The digest identifies bytes read for this operation; it cannot prove that a server-backed player already loaded the same bytes or that the server will keep them unchanged.',
    };
    files['manifest.json'] = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)));
    files['README.txt'] = Uint8List.fromList(
      utf8.encode(
        'This archive contains the exact original subtitle bytes and a separate corrected copy. '
        'The original is unchanged. The corrected file uses the opened media part clock and follows the explicit cue anchors. '
        'No player preference, server track, or library asset was changed by export. '
        'The manifest records content hashes and the limits of server-side identity.\n',
      ),
    );
    final total = files.values.fold<int>(0, (sum, value) => sum + value.length);
    if (total > maximumArchiveBytes) throw const FormatException('The calibration export exceeds 12 MiB.');
    final archive = Archive();
    for (final entry in files.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    final output = ZipEncoder().encode(archive);
    if (output.length > maximumArchiveBytes) throw const FormatException('The calibration export exceeds 12 MiB.');
    return Uint8List.fromList(output);
  }

  static String _safeFileName(String input, String extension) {
    final leaf = input.replaceAll('\\', '/').split('/').last;
    final cleaned = leaf.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final base = cleaned.isEmpty ? 'subtitle$extension' : cleaned;
    final normalizedExtension = extension.toLowerCase();
    final output = base.toLowerCase().endsWith(normalizedExtension) ? base : '$base$normalizedExtension';
    return output.length <= 120 ? output : output.substring(output.length - 120);
  }
}
