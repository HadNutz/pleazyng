import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../utils/bounded_picked_file.dart';
import 'source_models.dart';

Future<Uint8List> readSourceFile(PlatformFile file, int maxBytes) =>
    readBoundedPickedFile(file, maxBytes, invalid: const SourceException(SourceFailure.invalidData));
