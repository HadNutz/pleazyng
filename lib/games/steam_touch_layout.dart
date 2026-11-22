import 'dart:convert';

import 'package:flutter/painting.dart';

/// Separate compact/wide layouts keep rotation from stacking controls. Values
/// are normalized over each control's available travel, preserving hit sizes.
class SteamTouchLayout {
  SteamTouchLayout({Map<String, Offset> wide = const {}, Map<String, Offset> compact = const {}})
    : wide = Map.unmodifiable(wide),
      compact = Map.unmodifiable(compact);
  final Map<String, Offset> wide, compact;
  static const controls = [
    'leftStick',
    'rightStick',
    'a',
    'b',
    'x',
    'y',
    'dpadUp',
    'dpadDown',
    'dpadLeft',
    'dpadRight',
    'leftBumper',
    'leftTrigger',
    'rightTrigger',
    'rightBumper',
    'select',
    'mode',
    'start',
  ];
  static double extent(String key) => key.endsWith('Stick') ? 88 : 48;
  static bool _wide(Size size) => size.width >= 640 || (size.width >= 496 && size.height < 352);
  static bool _shortDeck(Size size) => !_wide(size) && size.height < 352;
  static bool fits(Size size) => _wide(size)
      ? size.height >= 216
      : _shortDeck(size)
      ? size.width >= 400 && size.height >= 256
      : size.width >= 304;
  static Offset position(Offset normalized, Size size, String key) => Offset(
    8 + normalized.dx.clamp(0.0, 1.0) * (size.width - 16 - extent(key)),
    8 + normalized.dy.clamp(0.0, 1.0) * (size.height - 16 - extent(key)),
  );
  static Offset normalize(Offset position, Size size, String key) => Offset(
    ((position.dx - 8) / (size.width - 16 - extent(key))).clamp(0.0, 1.0),
    ((position.dy - 8) / (size.height - 16 - extent(key))).clamp(0.0, 1.0),
  );
  static Map<String, Offset> defaults(Size size, {bool swapSides = false}) {
    final wide = _wide(size);
    final groupWidth = wide ? 240.0 : 144.0;
    final left = swapSides ? size.width - 8 - groupWidth : 8.0;
    final right = swapSides ? 8.0 : size.width - 8 - groupWidth;
    final top = size.height - (wide ? 152 : 288);
    final positions = <String, Offset>{};
    void cross(double x, double y, List<String> names) {
      for (final entry in [Offset(48, 0), Offset(0, 48), Offset(96, 48), Offset(48, 96)].asMap().entries) {
        positions[names[entry.key]] = Offset(x, y) + entry.value;
      }
    }

    if (_shortDeck(size)) {
      final middle = size.width / 2;
      final sticksY = 8.0;
      final leftX = swapSides ? size.width - 96 : 8.0;
      final rightX = swapSides ? 8.0 : size.width - 96;
      positions['leftStick'] = Offset(leftX, sticksY);
      positions['rightStick'] = Offset(rightX, sticksY);
      final shoulders = ['leftBumper', 'leftTrigger', 'rightTrigger', 'rightBumper'];
      for (var i = 0; i < shoulders.length; i++) {
        positions[shoulders[i]] = Offset(middle - 96 + 48 * (swapSides ? 3 - i : i), sticksY);
      }
      for (var i = 0; i < 3; i++) {
        positions[['select', 'mode', 'start'][i]] = Offset(middle - 72 + 48 * i, sticksY + 48);
      }
      cross(left, size.height - 152, ['dpadUp', 'dpadLeft', 'dpadRight', 'dpadDown']);
      cross(right, size.height - 152, ['y', 'x', 'b', 'a']);
      return positions.map((key, value) => MapEntry(key, normalize(value, size, key)));
    }

    cross(left, top + (wide ? 0 : 136), ['dpadUp', 'dpadLeft', 'dpadRight', 'dpadDown']);
    cross(right + (wide ? 96 : 0), top + (wide ? 0 : 48), ['y', 'x', 'b', 'a']);
    positions['leftBumper'] = Offset(left + (wide ? 144 : 24), top + (wide ? 4 : 0));
    positions['leftTrigger'] = positions['leftBumper']! + const Offset(48, 0);
    positions['rightTrigger'] = Offset(right + (wide ? 0 : 24), top + (wide ? 4 : 0));
    positions['rightBumper'] = positions['rightTrigger']! + const Offset(48, 0);
    positions['leftStick'] = Offset(left + (wide ? 148 : 28), top + (wide ? 52 : 48));
    positions['rightStick'] = Offset(right + (wide ? 4 : 28), top + (wide ? 52 : 192));
    for (var i = 0; i < 3; i++) {
      positions[['select', 'mode', 'start'][i]] = Offset(size.width / 2 - 72 + 48 * i, 8);
    }
    return positions.map((key, value) => MapEntry(key, normalize(value, size, key)));
  }

  Map<String, Offset> resolve(Size size, {bool swapSides = false}) {
    final saved = _wide(size) ? wide : compact;
    final fallback = defaults(size, swapSides: swapSides);
    final candidate = {...fallback, ...saved};
    return valid(candidate, size) ? candidate : fallback;
  }

  static bool valid(Map<String, Offset> values, Size size) {
    if (!fits(size) || values.length != controls.length || !controls.every(values.containsKey)) return false;
    final rects = <Rect>[];
    for (final key in controls) {
      final value = values[key]!;
      if (!value.dx.isFinite || !value.dy.isFinite || value.dx < 0 || value.dx > 1 || value.dy < 0 || value.dy > 1) {
        return false;
      }
      final rect = position(value, size, key) & Size.square(extent(key));
      // Half-pixel tolerance avoids floating point rejection of touching edges.
      if (rects.any((other) => other.deflate(.5).overlaps(rect.deflate(.5)))) return false;
      rects.add(rect);
    }
    return true;
  }

  SteamTouchLayout replace(Size size, Map<String, Offset> positions) {
    if (!valid(positions, size)) throw const FormatException('Invalid touch layout');
    return _wide(size)
        ? SteamTouchLayout(wide: positions, compact: compact)
        : SteamTouchLayout(wide: wide, compact: positions);
  }

  String encode() => jsonEncode({'version': 1, 'wide': _encode(wide), 'compact': _encode(compact)});
  static Map<String, List<double>> _encode(Map<String, Offset> value) =>
      value.map((key, point) => MapEntry(key, [point.dx, point.dy]));
  static SteamTouchLayout restore(String? value) {
    if (value == null || value.length > 8192) return SteamTouchLayout();
    try {
      final data = jsonDecode(value);
      if (data is! Map || data['version'] != 1) return SteamTouchLayout();
      Map<String, Offset> read(Object? raw) {
        if (raw is! Map || raw.length > controls.length) throw const FormatException();
        final result = <String, Offset>{};
        for (final key in raw.keys) {
          final point = raw[key];
          if (!controls.contains(key) ||
              point is! List ||
              point.length != 2 ||
              point.any((v) => v is! num || !v.isFinite || v < 0 || v > 1)) {
            throw const FormatException();
          }
          result[key as String] = Offset((point[0] as num).toDouble(), (point[1] as num).toDouble());
        }
        return result;
      }

      return SteamTouchLayout(wide: read(data['wide']), compact: read(data['compact']));
    } catch (_) {
      // best-effort: Keep touch controls usable with the built-in layout.
      return SteamTouchLayout();
    }
  }
}
