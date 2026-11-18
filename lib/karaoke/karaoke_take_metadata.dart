import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Replace the metadata in the same directory so readers see a complete take.
Future<void> writeTakeMetadata(Directory directory, Map<String, dynamic> data) async {
  final target = p.join(directory.path, 'take.json');
  final pending = File('$target.${const Uuid().v4()}.pending');
  try {
    await pending.writeAsString(jsonEncode(data), flush: true);
    await pending.rename(target);
  } finally {
    if (await pending.exists()) await pending.delete();
  }
}
