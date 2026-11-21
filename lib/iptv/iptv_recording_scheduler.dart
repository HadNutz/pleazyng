import 'dart:async';
import 'dart:io';

import 'package:disk_usage/disk_usage.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../utils/app_logger.dart';
import '../media/live_tv_support.dart';
import '../sources/source_models.dart';
import 'iptv_models.dart';
import 'iptv_live_tv_session.dart';
import 'iptv_scheduled_stream_recorder.dart';
import 'iptv_hls_archive.dart';
import 'iptv_source_repository.dart';

/// Runs one-off local IPTV schedules while Pleazyng is running. Dispatcharr
/// remains the durable server-side scheduler for devices that may be offline.
class IptvRecordingScheduler with WidgetsBindingObserver {
  IptvRecordingScheduler(this._repository) {
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_recovered ? _tick() : _recoverAndTick());
    });
    unawaited(_recoverAndTick());
  }

  final IptvSourceRepository _repository;
  final Map<String, IptvScheduledStreamRecorder> _active = {};
  final _activeSchedules = <String, IptvLocalRecordingSchedule>{};
  final _extending = <String>{};
  final changes = ValueNotifier<int>(0);
  Iterable<IptvLocalRecordingSchedule> activeFor(String? profile, String? source, String? channel) =>
      _activeSchedules.values.where((s) => s.profileId == profile && s.sourceId == source && s.channelId == channel);

  Future<DateTime?> extend(IptvLocalRecordingSchedule schedule) async {
    final capture = _active[schedule.id];
    if (capture == null ||
        !capture.canExtend ||
        _activeSchedules[schedule.id]?.profileId != schedule.profileId ||
        !_extending.add(schedule.id)) {
      return null;
    }
    final previous = capture.endsAt;
    final next = previous.add(const Duration(minutes: 30));
    capture.setDeadline(next);
    try {
      if (!await _repository.saveActiveRecordingDeadline(schedule, previous, next)) {
        capture.setDeadline(previous);
        return null;
      }
      return next;
    } catch (_) {
      capture.setDeadline(previous);
      rethrow;
    } finally {
      _extending.remove(schedule.id);
      if (!_disposed) changes.value++;
    }
  }

  final _workers = <String, ({String profileId, Future<void> done})>{};
  final _removals = <Object, String?>{};

  bool _removing(String profileId) => _removals.values.any((id) => id == null || id == profileId);

  /// Keep timers from starting or publishing a final file after its catalog
  /// entry has been deleted. Other profiles keep recording during this work.
  Future<void> deleteProfileRecordings({String? profileId}) async {
    final operation = Object();
    _removals[operation] = profileId;
    try {
      // Startup recovery may still be publishing the surviving partial path.
      await _recovery?.future;
      final workers = _workers.entries.where((e) => profileId == null || e.value.profileId == profileId).toList();
      await Future.wait([
        for (final worker in workers) worker.value.done,
        for (final worker in workers)
          if (_active[worker.key] case final capture?) capture.stop(),
      ]);
      if (profileId == null) {
        await _repository.deleteAllProfiles();
      } else {
        await _repository.deleteProfile(profileId);
      }
    } finally {
      _removals.remove(operation);
    }
  }

  final _uuid = const Uuid();
  Timer? _timer;
  bool _ticking = false;
  bool _disposed = false;
  bool _recovered = false;
  Completer<void>? _recovery;

  Future<void> _recoverAndTick() async {
    if (_disposed || _recovered || _recovery != null || _removals.isNotEmpty) {
      return;
    }
    final recovery = _recovery = Completer<void>();
    try {
      await _repository.recoverLocalRecordingSchedules();
      _recovered = true;
      await _tick();
    } on Object catch (error, stackTrace) {
      appLogger.w('Could not recover IPTV recording schedules', error: error, stackTrace: stackTrace);
    } finally {
      _recovery = null;
      recovery.complete();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_tick());
    }
  }

  Future<void> _tick() async {
    if (_disposed || !_recovered || _ticking) {
      return;
    }
    _ticking = true;
    try {
      final schedules = await _repository.dueLocalRecordingSchedules();
      final now = DateTime.now();
      for (final schedule in schedules) {
        if (_disposed || _removing(schedule.profileId) || _workers.containsKey(schedule.id)) {
          continue;
        }
        if (!schedule.endsAt.isAfter(now)) {
          await _repository.updateLocalRecordingSchedule(schedule.id, state: 'missed', errorCode: 'app_not_running');
        } else if (!schedule.startsAt.isAfter(now)) {
          final work = _record(schedule);
          _workers[schedule.id] = (profileId: schedule.profileId, done: work);
          unawaited(work.whenComplete(() => _workers.remove(schedule.id)));
        }
      }
    } catch (error, stackTrace) {
      appLogger.w('IPTV recording scheduler tick failed', error: error, stackTrace: stackTrace);
    } finally {
      _ticking = false;
    }
  }

  Future<void> _record(IptvLocalRecordingSchedule schedule) async {
    String? recordingId;
    String? profileId;
    DateTime? startedAt;
    File? partial;
    File? target;
    IptvScheduledStreamRecorder? recorder;
    LiveTvPlaybackSession? session;
    try {
      await _repository.updateLocalRecordingSchedule(schedule.id, state: 'starting');
      final config = await _repository.configuration(schedule.profileId, schedule.sourceId);
      if (config == null) {
        throw const IptvImportException('source_missing');
      }
      if (!await _repository.seriesRules.canCapture(
        schedule.id,
        schedule.profileId,
        schedule.sourceId,
        schedule.channelId,
      )) {
        throw const IptvImportException('permission');
      }
      session = await _repository.startPlayback(schedule.profileId, schedule.sourceId, schedule.channelId);
      if (session == null) {
        throw const IptvImportException('source_missing');
      }
      final streamUrl = await session.streamUrlAt();
      final uri = streamUrl == null ? null : Uri.tryParse(streamUrl);
      if (uri == null || uri.host.isEmpty || !const {'http', 'https'}.contains(uri.scheme)) {
        throw const IptvImportException('invalid_stream_address');
      }

      final now = DateTime.now();
      if (!IptvLocalRecordingSchedule.canSchedule(start: schedule.startsAt, end: schedule.endsAt, now: now)) {
        throw const IptvImportException('recording_schedule_invalid');
      }
      final root = await getApplicationSupportDirectory();
      final folder = Directory(p.join(root.path, 'iptv-recordings', iptvRecordingSlug(schedule.profileId)));
      await folder.create(recursive: true);
      try {
        final available = await DiskUsage.freeSpace(folder.path).timeout(const Duration(seconds: 3));
        if (available != null && available < 512 * 1024 * 1024) {
          throw const IptvImportException('storage_low');
        }
      } on IptvImportException {
        rethrow;
      } on Object {
        // Embedded targets may not expose a free-space probe.
      }
      final id = _uuid.v4();
      final slug = iptvRecordingSlug(
        schedule.programmeTitle?.isNotEmpty == true ? schedule.programmeTitle! : schedule.title,
      );
      final stamp = now.toUtc().millisecondsSinceEpoch;
      final recordingTarget = File(p.join(folder.path, '${stamp}_${slug}_${id.substring(0, 8)}.ts'));
      final recordingPartial = File(p.join(folder.path, '.$id.partial.ts'));
      recordingId = id;
      profileId = schedule.profileId;
      startedAt = now;
      target = recordingTarget;
      partial = recordingPartial;
      await _repository.beginLocalRecording(
        IptvLocalRecording(
          id: id,
          profileId: schedule.profileId,
          sourceId: schedule.sourceId,
          channelId: schedule.channelId,
          title: schedule.title,
          programmeTitle: schedule.programmeTitle,
          // Journal the file that exists during capture so process-death
          // recovery can retain it before final publication/rename.
          filePath: recordingPartial.path,
          startedAt: now,
          state: 'recording',
        ),
      );
      await _repository.updateLocalRecordingSchedule(schedule.id, state: 'recording', recordingId: id);
      if (_disposed || _removing(schedule.profileId)) throw const IptvImportException('recording_interrupted');
      final capture = IptvScheduledStreamRecorder(
        uri: uri,
        allowHttp: config.allowHttp,
        headers: session is IptvLiveTvPlaybackSession ? session.streamHeaders : const <String, String>{},
        outputFile: recordingPartial,
        archiveDirectory: Directory(p.join(folder.path, '.$id.media')),
        endsAt: schedule.endsAt,
        requestedStart: schedule.startsAt.isAfter(schedule.createdAt) ? schedule.startsAt : schedule.createdAt,
      );
      recorder = capture;
      _active[schedule.id] = capture;
      _activeSchedules[schedule.id] = schedule;
      if (!_disposed) changes.value++;
      final extension = await capture.record();
      if (_disposed || _removing(schedule.profileId)) {
        throw const IptvImportException('recording_interrupted');
      }
      if (!capture.capturedThroughDeadline) throw const IptvImportException('recording_interrupted');
      if (!await recordingPartial.exists() || await recordingPartial.length() == 0) {
        throw const IptvImportException('recording_empty');
      }
      final size = await IptvHlsArchive.retainedBytes(recordingPartial);
      if (size <= 0) {
        throw const IptvImportException('recording_empty');
      }
      final extensionlessTarget = recordingTarget.path.substring(0, recordingTarget.path.lastIndexOf('.'));
      final completedTarget = File('$extensionlessTarget$extension');
      if (await completedTarget.exists()) {
        throw const IptvImportException('recording_conflict');
      }
      await _repository.updateLocalRecordingFilePath(
        profileId: schedule.profileId,
        recordingId: id,
        filePath: completedTarget.path,
      );
      await recordingPartial.rename(completedTarget.path);
      target = completedTarget;
      await _repository.finishLocalRecording(
        profileId: schedule.profileId,
        recordingId: id,
        completed: true,
        durationSeconds: (capture.capturedMediaDuration ?? DateTime.now().difference(now)).inSeconds,
        sizeBytes: size,
      );
      await _repository.updateLocalRecordingSchedule(schedule.id, state: 'completed', recordingId: id);
    } on Object catch (error, stackTrace) {
      appLogger.w('IPTV scheduled recording failed', error: error, stackTrace: stackTrace);
      final errorCode = _captureErrorCode(error);
      try {
        if (partial != null && await partial.exists()) {
          if (await IptvHlsArchive.retainedBytes(partial) > 0) {
            // A failed programme is still useful when it contains recorded
            // media. Retain it with a normal playable extension and an
            // interrupted state; never delete it merely because capture ended.
            final retainedPath = '${partial.path}.incomplete${recorder?.fileExtension ?? '.ts'}';
            if (recordingId != null && profileId != null) {
              await _repository.updateLocalRecordingFilePath(
                profileId: profileId,
                recordingId: recordingId,
                filePath: retainedPath,
              );
            }
            target = await partial.rename(retainedPath);
          } else {
            await partial.delete();
          }
        }
        if (recordingId != null && profileId != null) {
          final retainedSize = target != null && await target.exists()
              ? await IptvHlsArchive.retainedBytes(target)
              : null;
          if (retainedSize != null && retainedSize > 0) {
            await _repository.updateLocalRecordingFilePath(
              profileId: profileId,
              recordingId: recordingId,
              filePath: target!.path,
            );
          }
          await _repository.finishLocalRecording(
            profileId: profileId,
            recordingId: recordingId,
            completed: false,
            durationSeconds:
                recorder?.capturedMediaDuration?.inSeconds ??
                (startedAt == null ? null : DateTime.now().difference(startedAt).inSeconds),
            sizeBytes: retainedSize,
            errorCode: errorCode,
          );
        }
        await _repository.updateLocalRecordingSchedule(
          schedule.id,
          state: 'failed',
          recordingId: recordingId,
          errorCode: errorCode,
        );
      } on Object catch (finalizeError, finalizeStackTrace) {
        appLogger.w(
          'Could not finalize IPTV scheduled recording',
          error: finalizeError,
          stackTrace: finalizeStackTrace,
        );
      }
    } finally {
      _active.remove(schedule.id);
      _activeSchedules.remove(schedule.id);
      if (!_disposed) changes.value++;
      if (recorder != null && !_disposed) {
        await recorder.stop();
      }
      if (session != null) {
        await session.discard();
      }
    }
  }

  static String _captureErrorCode(Object error) => switch (error) {
    IptvImportException(:final code) => code,
    UnsupportedError() => 'recording_encrypted_hls',
    SourceException(reason: SourceFailure.authentication) => 'authentication',
    SourceException(reason: SourceFailure.permission) => 'permission',
    SourceException(reason: SourceFailure.invalidData) => 'invalid_data',
    SourceException() => 'capture_failed',
    _ => 'capture_failed',
  };

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    for (final recorder in _active.values.toList(growable: false)) {
      await recorder.stop();
    }
    _active.clear();
    changes.dispose();
  }
}
