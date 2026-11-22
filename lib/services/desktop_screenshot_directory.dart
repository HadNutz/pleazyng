import 'dart:io';

import 'package:flutter/services.dart';

import '../utils/app_logger.dart';
import 'file_picker_service.dart';

class DesktopScreenshotDirectory {
  static const defaultPath = '~/Pictures';
  static const _channel = MethodChannel('com.pleazyng/screenshot_directory');

  static Future<String?> choose(String title) async {
    if (!Platform.isMacOS) return FilePickerService.instance.getDirectoryPath(dialogTitle: title);
    try {
      return await _channel.invokeMethod<String>('choose', title);
    } on PlatformException catch (e) {
      throw FileSystemException(e.message ?? e.code);
    }
  }

  static Future<String> resolve(String? path) async {
    if (path == null || path.isEmpty) return defaultPath;
    if (!Platform.isMacOS) return path;
    try {
      return await _channel.invokeMethod<String>('resolve') ?? defaultPath;
    } on PlatformException catch (e) {
      appLogger.d('Could not reopen the selected screenshot directory', error: e.code);
      return defaultPath;
    }
  }

  static Future<void> reset() async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod<void>('reset');
    } on PlatformException catch (e) {
      throw FileSystemException(e.message ?? e.code);
    }
  }
}
