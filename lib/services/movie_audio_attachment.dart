import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../mpv/mpv.dart';
import '../media/media_item.dart';

String? movieAudioKey(String? profile, MediaItem? item, int version, int? part) {
  if (profile == null || item == null || item.serverId == null) return null;
  final selected = item.mediaVersions?.elementAtOrNull(version);
  final physical = selected?.parts.where((p) => p.id == part?.toString()).firstOrNull ?? selected?.parts.firstOrNull;
  if (physical == null || physical.id.isEmpty && (physical.file?.isEmpty ?? true)) return null;
  return 'movie-audio-v1-${sha256.convert(utf8.encode(jsonEncode([profile, item.serverId, item.id, selected?.id ?? version, part ?? physical.id, physical.file, physical.sizeBytes, physical.durationMs ?? item.durationMs])))}';
}

/// One mpv clock and output. A commentary file is copied into app storage;
/// removing it never deletes the user's original file.
class MovieAudioAttachment {
  MovieAudioAttachment(this.player, this.key);
  final Player player;
  final String key;
  String? path, label;
  bool mix = false;
  double movieGain = 1, voiceGain = 1;
  int delayMs = 0;
  String? _externalId, _originalId, _graph, _originalDelay, _originalSpdif, _trackAddress;
  static final _sessions = Expando<MovieAudioAttachment>();
  static MovieAudioAttachment forCut(Player p, String key) {
    final old = _sessions[p];
    if (old != null && old.key == key) return old;
    return _sessions[p] = MovieAudioAttachment(p, key);
  }

  Future<void> read() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return;
    try {
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return;
      final filename = data['asset'];
      if (filename is! String ||
          filename.isEmpty ||
          filename == '.' ||
          filename == '..' ||
          p.basename(filename) != filename) {
        return;
      }
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'movie-audio', key, filename));
      if (!await file.exists()) return;
      path = file.path;
      label = data['label'] is String ? data['label'] as String : p.basename(file.path);
      mix = data['mix'] == true;
      double gain(Object? v) => v is num && v.isFinite ? v.toDouble().clamp(0, 1) : 1;
      movieGain = gain(data['movie']);
      voiceGain = gain(data['voice']);
      delayMs = data['delay'] is int ? (data['delay'] as int).clamp(-30000, 30000) : 0;
    } on FormatException {
      // A corrupt optional preference must not prevent ordinary playback.
    }
  }

  Future<void> persist() async {
    if (path == null) return;
    final saved = await (await SharedPreferences.getInstance()).setString(
      key,
      jsonEncode({
        'asset': p.basename(path!),
        'label': label,
        'mix': mix,
        'movie': movieGain,
        'voice': voiceGain,
        'delay': delayMs,
      }),
    );
    if (!saved) throw StateError('Attached audio could not be saved');
  }

  Future<void> attach(File source, String name, bool asMix, bool Function() current) async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'movie-audio', key));
    await dir.create(recursive: true);
    final owned = File(p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}${p.extension(name)}'));
    final old = (path: path, label: label, mix: mix, delay: delayMs, movie: movieGain, voice: voiceGain);
    await source.copy(owned.path);
    try {
      if (!current()) return;
      await detach();
      if (!current()) return;
      path = owned.path;
      label = name;
      mix = asMix;
      delayMs = 0;
      movieGain = voiceGain = 1;
      await apply(current);
      if (!current()) {
        path = old.path;
        label = old.label;
        mix = old.mix;
        delayMs = old.delay;
        movieGain = old.movie;
        voiceGain = old.voice;
        return;
      }
      await persist();
    } catch (_) {
      if (current()) await detach();
      path = old.path;
      label = old.label;
      mix = old.mix;
      delayMs = old.delay;
      movieGain = old.movie;
      voiceGain = old.voice;
      if (current() && old.path != null) await apply(current);
      rethrow;
    } finally {
      if (path != owned.path && await owned.exists()) await owned.delete();
    }
    if (old.path != null && old.path != path && await File(old.path!).exists()) await File(old.path!).delete();
  }

  /// Cutting the external input's own timeline advances it on *every* seek.
  /// atrim + PTS-STARTPTS would advance only the first open and drift on seek.
  String get playbackAddress {
    final uri = File(path!).uri.toString();
    return mix && delayMs < 0 ? 'edl://%${utf8.encode(uri).length}%$uri,${-delayMs / 1000}' : uri;
  }

  Future<void> apply(bool Function() current) async {
    final file = path;
    if (file == null || !current() || !await File(file).exists() || !current()) return;
    final active = await player.getProperty('lavfi-complex') ?? '';
    if (!current()) return;
    if (active.isNotEmpty && active != _graph) throw StateError('Another audio mix is active');
    final position = player.currentPosition, wasPlaying = player.state.playing;
    await player.pause();
    try {
      if (!current()) return;
      _originalId ??= await player.getProperty('aid');
      _originalDelay ??= await player.getProperty('audio-delay');
      _originalSpdif ??= await player.getProperty('audio-spdif');
      final address = playbackAddress;
      if (!current()) return;
      if (_externalId != null && _trackAddress != address) {
        if (_graph != null) {
          await player.setProperty('file-local-options/lavfi-complex', '');
          _graph = null;
        }
        if (!current()) return;
        await player.command(['audio-remove', _externalId!]);
        _externalId = null;
      }
      if (_externalId == null) {
        await player.command(['audio-add', address, 'auto']);
        if (!current()) return;
        _trackAddress = address;
        final count = int.tryParse(await player.getProperty('track-list/count') ?? '') ?? 0;
        for (var i = 0; i < count; i++) {
          if (!current()) return;
          final external = await player.getProperty('track-list/$i/external-filename');
          if (external == address || external == file) {
            _externalId = await player.getProperty('track-list/$i/id');
            break;
          }
        }
      }
      if (!current()) return;
      final id = _externalId, base = _originalId;
      if (id == null || !RegExp(r'^\d+$').hasMatch(id)) throw StateError('Audio track could not be opened');
      if (mix) {
        if (base == null || !RegExp(r'^\d+$').hasMatch(base)) throw StateError('Movie soundtrack is unavailable');
        final timing = delayMs > 0 ? 'adelay=$delayMs:all=1,' : '';
        final graph =
            '[aid$base]volume=${movieGain.toStringAsFixed(3)}[movie];'
            '[aid$id]${timing}volume=${voiceGain.toStringAsFixed(3)}[voice];'
            '[movie][voice]amix=inputs=2:duration=first:normalize=0,alimiter=level=0[ao]';
        await player.setProperty('file-local-options/audio-spdif', '');
        if (!current()) return;
        await player.setProperty('file-local-options/lavfi-complex', graph);
        _graph = graph;
        if (!current()) return;
        await player.setProperty('file-local-options/audio-delay', _originalDelay ?? '0');
      } else {
        if (_graph != null) await player.setProperty('file-local-options/lavfi-complex', '');
        _graph = null;
        if (!current()) return;
        await player.setProperty('aid', id);
        if (!current()) return;
        await player.setProperty('file-local-options/audio-delay', (delayMs / 1000).toString());
      }
      // Rebuild both decoder inputs at the same point after changing the graph.
      if (current()) await player.seek(position);
    } catch (_) {
      if (current()) await detach();
      rethrow;
    } finally {
      if (wasPlaying && current()) await player.play();
    }
  }

  Future<void> detach() async {
    if (_graph != null && await player.getProperty('lavfi-complex') == _graph) {
      await player.setProperty('file-local-options/lavfi-complex', '');
    }
    _graph = null;
    if (_externalId != null) {
      if (_originalId != null) await player.setProperty('aid', _originalId!);
      if (_originalDelay != null) await player.setProperty('file-local-options/audio-delay', _originalDelay!);
      if (_originalSpdif != null) await player.setProperty('file-local-options/audio-spdif', _originalSpdif!);
      await player.command(['audio-remove', _externalId!]);
    }
    _externalId = null;
    _trackAddress = null;
  }

  Future<void> forget() async {
    await detach();
    await (await SharedPreferences.getInstance()).remove(key);
    final file = path;
    path = null;
    label = null;
    if (file != null && await File(file).exists()) await File(file).delete();
  }

  // loadfile starts a fresh track list and file-local graph.
  void opened() {
    _externalId = _trackAddress = _graph = _originalId = _originalDelay = _originalSpdif = null;
  }
}
