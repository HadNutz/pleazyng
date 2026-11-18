import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../mpv/player/player.dart';
import '../mpv/player/player_native.dart';
import '../utils/app_logger.dart';
import 'settings_service.dart';

enum StereoLane { stereo, left, right }

typedef PresentationSource = ({String file, String display, bool stereoSource});

String presentationKey(Iterable<Object?> parts) => sha256.convert(utf8.encode(jsonEncode(parts.toList()))).toString();

/// Text colour fallback for embedded VOs. The percentage scales linear light
/// to retain the hue of a custom foreground and the appearance of outlines.
String scaledSubtitleColor(String color, int percent) {
  if (!RegExp(r'^#(?:[a-f0-9]{2})?[a-f0-9]{6}$', caseSensitive: false).hasMatch(color)) color = '#FFFFFF';
  if (percent == 100) return color;
  final alpha = color.length == 9 ? color.substring(1, 3) : '';
  final offset = alpha.length;
  int channel(int i) {
    i += offset;
    final v = int.parse(color.substring(i, i + 2), radix: 16) / 255;
    final linear = (v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) * percent / 100;
    return ((linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055) * 255).round().clamp(0, 255);
  }

  return '#$alpha${[1, 3, 5].map((i) => channel(i).toRadixString(16).padLeft(2, '0')).join()}';
}

String? hdrSubtitleControl({
  required String? target,
  required String? source,
  required String? vo,
  required String? codec,
  required bool nativeText,
  required bool nativeBitmap,
}) {
  const hdr = {'pq', 'hlg', 'st2084', 'smpte2084'};
  if (!hdr.contains(target) || codec == null) return null;
  const bitmap = {'hdmv_pgs_subtitle', 'dvd_subtitle', 'dvb_subtitle', 'pgssub', 'dvdsub', 'dvbsub', 'xsub'};
  if (bitmap.contains(codec)) {
    return hdr.contains(source) && vo == 'gpu-next' && nativeBitmap ? 'image-subs-hdr-peak' : null;
  }
  if (vo == 'gpu-next' && nativeText) return 'sub-hdr-peak';
  return {'subrip', 'srt', 'text', 'mov_text', 'webvtt'}.contains(codec) ? 'sub-color' : null;
}

bool decodedStereo(String? channels, String? format) =>
    {'stereo', 'fl-fr'}.contains(channels?.toLowerCase()) &&
    format != null &&
    format.isNotEmpty &&
    !format.toLowerCase().contains('spdif') &&
    !format.toLowerCase().contains('iec61937');

class PlaybackPresentation extends ChangeNotifier {
  PlaybackPresentation(this.player, this.source) {
    _sessions[player] = this;
    player.onPresentationChanged = refresh;
    refresh();
  }
  static final _sessions = Expando<PlaybackPresentation>();
  static PlaybackPresentation? of(Player player) => _sessions[player];
  final PlayerBase player;
  final PresentationSource? Function() source;
  bool _closed = false;
  Timer? _debounce;
  Future<void> _tail = Future.value();
  String? hdrKey, stereoKey, _activeProperty, _original;
  StereoLane lane = StereoLane.stereo;
  int brightness = 100;
  final _draftBrightness = <String, int>{};
  final _draftLane = <String, StereoLane>{};
  Future<String?> _read(String property) async {
    try {
      final v = await player.getProperty(property);
      return v == null || v.isEmpty || v == 'unavailable' ? null : v;
    } catch (_) {
      return null;
    }
  }

  void subtitleStyleApplied(String foreground) {
    if (_activeProperty == 'sub-color') _original = foreground;
    refresh();
  }

  void refresh() {
    if (_closed) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 45), () {
      _run(_sync).catchError((Object e, StackTrace st) {
        appLogger.d('Player presentation update failed', error: e, stackTrace: st);
      });
    });
  }

  Future<void> _run(Future<void> Function() action) {
    final task = _tail.then((_) async {
      if (!_closed) await action();
    });
    _tail = task.catchError((Object _) {});
    return task;
  }

  Future<void> chooseLane(String key, StereoLane? value, {bool save = false}) => _run(() async {
    if (key != stereoKey || key != 'dualMono.${source()?.file}') return;
    final settings = await SettingsService.getInstance();
    if (value == null) {
      _draftLane.remove(key);
    } else {
      _draftLane[key] = value;
    }
    try {
      await _sync();
    } catch (_) {
      _draftLane.remove(key);
      rethrow;
    }
    if (save && value != null && stereoKey == key) {
      await settings.writeString(key, value.name);
      _draftLane.remove(key);
    }
  });
  Future<void> chooseBrightness(String key, int? value, {bool save = false}) => _run(() async {
    if (key != hdrKey) return;
    final settings = await SettingsService.getInstance();
    if (value == null) {
      _draftBrightness.remove(key);
    } else {
      _draftBrightness[key] = value.clamp(10, 100);
    }
    try {
      await _sync();
    } catch (_) {
      _draftBrightness.remove(key);
      rethrow;
    }
    if (save && value != null && hdrKey == key) {
      await settings.writeInt(key, value.clamp(10, 100));
      _draftBrightness.remove(key);
    }
  });

  Future<void> _sync() async {
    final identity = source();
    final settings = await SettingsService.getInstance();
    final nativeMpv = player is PlayerNative;
    final values = nativeMpv
        ? await Future.wait(
            [
              'video-target-params/gamma',
              'video-params/gamma',
              'current-vo',
              'current-tracks/sub/codec',
              'display-names',
              'audio-params/channels',
              'audio-out-params/format',
            ].map(_read),
          )
        : List<String?>.filled(7, null);
    final [target, input, vo, codec, display, channels, format] = values;
    if (_closed || source() != identity) return;
    final stereoPcm = nativeMpv ? decodedStereo(channels, format) : await _read('dual-mono-available') == 'yes';
    final stereo = identity != null && identity.stereoSource && stereoPcm ? 'dualMono.${identity.file}' : null;
    final nextLane = stereo == null
        ? StereoLane.stereo
        : (_draftLane[stereo] ??
              StereoLane.values.where((v) => v.name == settings.readNullableString(stereo)).firstOrNull ??
              StereoLane.stereo);
    await player.setDualMonoChannel(switch (nextLane) {
      StereoLane.stereo => null,
      StereoLane.left => 0,
      StereoLane.right => 1,
    });
    final hd = target == 'pq' || target == 'hlg' || target == 'st2084' || target == 'smpte2084';
    final property = identity == null || !hd
        ? null
        : hdrSubtitleControl(
            target: target,
            source: input,
            vo: vo,
            codec: codec,
            nativeText: vo == 'gpu-next' && await _read('sub-hdr-peak') != null,
            nativeBitmap: vo == 'gpu-next' && await _read('image-subs-hdr-peak') != null,
          );
    if (_closed || source() != identity) return;
    final key = property == null
        ? null
        : 'hdrSub.${presentationKey([display == null || display == '[]' ? identity!.display : display, property == 'image-subs-hdr-peak' ? 'bitmap' : 'text'])}';
    final level = key == null ? 100 : (_draftBrightness[key] ?? settings.readNullableInt(key) ?? 100).clamp(10, 100);
    if (_activeProperty != null && (_activeProperty != property || level == 100)) {
      await player.setProperty(_activeProperty!, _original!);
      _activeProperty = null;
      _original = null;
    }
    if (property != null && level != 100) {
      if (_activeProperty != property) {
        _original = await _read(property);
        if (_original == null) return;
        _activeProperty = property;
      }
      final white =
          double.tryParse(_original!) ??
          (property == 'image-subs-hdr-peak' ? 1000 : double.tryParse(await _read('hdr-reference-white') ?? '') ?? 203);
      final value = property == 'sub-color'
          ? scaledSubtitleColor(_original!, level)
          : ((white > 0 ? white : 203) * level / 100).round().clamp(10, 10000).toString();
      if ((await _read(property))?.toLowerCase() != value.toLowerCase()) await player.setProperty(property, value);
    }
    if (_closed) return;
    if (stereoKey != stereo || hdrKey != key || brightness != level || lane != nextLane) {
      if (stereoKey != stereo) _draftLane.clear();
      if (hdrKey != key) _draftBrightness.clear();
      stereoKey = stereo;
      hdrKey = key;
      brightness = level;
      lane = nextLane;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _debounce?.cancel();
    player.onPresentationChanged = null;
    _sessions[player] = null;
    super.dispose();
  }
}
