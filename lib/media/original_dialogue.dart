import '../services/settings_service.dart';
import '../utils/language_codes.dart';
import 'media_source_info.dart';

/// A title's declared original language is evidence. Account language,
/// metadata display language, production country and track order are not.
MediaAudioTrack? originalDialogue(List<MediaAudioTrack> tracks, {String? language}) {
  final main = tracks
      .where(
        (t) =>
            !t.dubbed &&
            !t.commentary &&
            !t.described &&
            !_alternate.hasMatch('${t.title ?? ''} ${t.displayTitle ?? ''}'),
      )
      .toList();
  final flagged = main.where((t) => t.original).toList();
  if (flagged.length == 1) return flagged.single;
  if (flagged.length > 1) return flagged.where((t) => t.isDefault).singleOrNull;
  final code = LanguageCodes.getIso6391Code(language ?? '');
  if (code == null) return null;
  return main.where((t) => LanguageCodes.getIso6391Code(t.languageCode ?? '') == code).singleOrNull;
}

final _alternate = RegExp(
  r'\b(commentary|audio description|descriptive audio|described video|visually impaired|dubbed)\b',
  caseSensitive: false,
);

int? preferredOriginalId(MediaSourceInfo? info, Object? language) {
  if (info == null || SettingsService.instanceOrNull?.read(SettingsService.preferOriginalDialogue) != true) return null;
  return originalDialogue(
    info.audioTracks,
    language: info.originalLanguage ?? (language is String ? language : null),
  )?.id;
}

Future<int?> serverOriginalId(MediaSourceInfo? info, Object? language, Future<String?> Function()? lookup) async {
  if (info == null || SettingsService.instanceOrNull?.read(SettingsService.preferOriginalDialogue) != true) return null;
  final local = preferredOriginalId(info, language);
  if (local != null ||
      lookup == null ||
      info.audioTracks.length < 2 ||
      info.audioTracks.any((t) => t.original) ||
      LanguageCodes.getIso6391Code(info.originalLanguage ?? (language is String ? language : '')) != null) {
    return local;
  }
  try {
    final verified = await lookup().timeout(const Duration(seconds: 2));
    return originalDialogue(info.audioTracks, language: verified)?.id;
  } on Object {
    return null;
  }
}
