import 'dart:convert';

import 'package:crypto/crypto.dart';

final _reservedDeviceName = RegExp(r'^(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)', caseSensitive: false);

/// Retains existing portable IDs. Other IDs get a stable single component
/// shared by filesystem downloads, Android document trees and sidecar lookups.
String downloadIdComponent(String id) {
  const prefix = 'id-sha256-';
  if (id.isNotEmpty &&
      !id.endsWith('.') &&
      !id.endsWith(' ') &&
      !id.toLowerCase().startsWith(prefix) &&
      !id.contains(RegExp(r'[<>:"/\\|?*\x00-\x1f]')) &&
      !_reservedDeviceName.hasMatch(id) &&
      utf8.encode(id).length <= 255) {
    return id;
  }
  return '$prefix${sha256.convert(utf8.encode(id))}';
}

String downloadFileExtension(String value) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$').hasMatch(value)) {
    throw const FormatException('Invalid download file extension.');
  }
  return value;
}
