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
  return 'movie-audio-v1-${sha256.convert(utf8.encode(jsonEncode([profile, item.serverId, item.id, selected?.id ?? version, part ?? physical?.id, physical?.file, physical?.sizeBytes, physical?.durationMs ?? item.durationMs])))}';
}

class MovieAudioAttachment {
  MovieAudioAttachment(this.player, this.key);
  final Player player;
  final String key;
  String? path, label;
  bool mix = false;
  double movieGain = 1, voiceGain = 1;
  int delayMs = 0;
  String? _externalId, _originalId, _graph, _originalDelay;
  static final _sessions = Expando<MovieAudioAttachment>();
  static MovieAudioAttachment forCut(Player p, String key) {
    final old = _sessions[p];
    if (old != null && old.key == key) return old;
    return _sessions[p] = MovieAudioAttachment(p, key);
  }

  Future<void> read() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final filename = data['asset'] as String;
    if (p.basename(filename) != filename) return;
    final dir = await getApplicationSupportDirectory();
    path = p.join(dir.path, 'movie-audio', key, filename);
    label = data['label'] as String?;
    mix = data['mix'] == true;
    movieGain = (data['movie'] as num? ?? 1).toDouble().clamp(0, 1);
    voiceGain = (data['voice'] as num? ?? 1).toDouble().clamp(0, 1);
    delayMs = (data['delay'] as int? ?? 0).clamp(-30000, 30000);
  }

  Future<void> persist() async {
    if (path == null) return;
    await (await SharedPreferences.getInstance()).setString(
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
  }

  Future<void> attach(File source, String name, bool asMix, bool Function() current) async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'movie-audio', key));
    await dir.create(recursive: true);
    final owned = File(p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}${p.extension(name)}'));
    final old = path;
    await source.copy(owned.path);
    try {
      if (!current()) return;
      await detach();
      path = owned.path;
      label = name;
      mix = asMix;
      delayMs = 0;
      await apply(current);
      await persist();
    } catch (_) {
      await detach();
      path = old;
      await read();
      rethrow;
    } finally {
      if (path != owned.path && await owned.exists()) await owned.delete();
    }
    if (old != null && old != path && await File(old).exists()) await File(old).delete();
  }

  Future<void> apply(bool Function() current) async {
    final file = path;
    if (file == null || !current() || !await File(file).exists() || !current()) return;
    final active = await player.getProperty('lavfi-complex') ?? '';
    if (active.isNotEmpty && active != _graph) throw StateError('Another audio mix is active');
    if (_externalId == null) {
      _originalId = await player.getProperty('aid');
      _originalDelay = await player.getProperty('audio-delay');
      if (!current()) return;
      await player.command(['audio-add', File(file).uri.toString(), 'auto']);
      final count = int.tryParse(await player.getProperty('track-list/count') ?? '') ?? 0;
      for (var i = 0; i < count; i++) {
        final external = await player.getProperty('track-list/$i/external-filename');
        if (external == file || external == File(file).uri.toString()) {
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
      final timing = delayMs >= 0 ? 'adelay=${delayMs}:all=1' : 'atrim=start=${-delayMs / 1000},asetpts=PTS-STARTPTS';
      final graph =
          '[aid$base]volume=${movieGain.toStringAsFixed(3)}[movie];[aid$id]$timing,volume=${voiceGain.toStringAsFixed(3)}[voice];[movie][voice]amix=inputs=2:duration=first:normalize=0,alimiter=level=0[ao]';
      await player.setProperty('file-local-options/lavfi-complex', graph);
      _graph = graph;
    } else {
      if (_graph != null) await player.setProperty('file-local-options/lavfi-complex', '');
      _graph = null;
      await player.setProperty('aid', id);
      await player.setProperty('file-local-options/audio-delay', (delayMs / 1000).toString());
    }
  }

  Future<void> detach() async {
    if (_graph != null && await player.getProperty('lavfi-complex') == _graph) {
      await player.setProperty('file-local-options/lavfi-complex', '');
    }
    if (_externalId != null) {
      if (_originalId != null) await player.setProperty('aid', _originalId!);
      if (_originalDelay != null) await player.setProperty('file-local-options/audio-delay', _originalDelay!);
      await player.command(['audio-remove', _externalId!]);
    }
    _externalId = null;
    _graph = null;
  }

  Future<void> forget() async {
    await detach();
    await (await SharedPreferences.getInstance()).remove(key);
    final file = path;
    path = null;
    label = null;
    if (file != null && await File(file).exists()) await File(file).delete();
  }

  // A newly opened native file has a fresh track list and file-local graph.
  void opened() {
    _externalId = null;
    _graph = null;
    _originalId = null;
    _originalDelay = null;
  }
}
