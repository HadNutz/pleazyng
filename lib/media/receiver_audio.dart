import '../services/settings_service.dart';
import '../utils/platform_detector.dart';
import 'media_source_info.dart';

bool get receiverAc3Enabled {
  final settings = SettingsService.instanceOrNull;
  return settings != null &&
      PlatformDetector.supportsAudioPassthrough() &&
      settings.read(SettingsService.receiverAc3) &&
      !settings.read(SettingsService.audioNormalization);
}

/// Apply the receiver constraint only to a selected, identified multichannel
/// source. Stereo PCM works over optical and native AC-3 already fits.
bool needsReceiverAc3(MediaSourceInfo? info, int? selectedId) {
  if (info == null || info.audioTracks.isEmpty) return false;
  final tracks = info.audioTracks;
  final id = selectedId ?? info.defaultAudioStreamIndex;
  final track = id != null
      ? tracks.where((t) => t.id == id).firstOrNull
      : tracks.where((t) => t.selected).firstOrNull ?? tracks.first;
  return track != null && (track.channels ?? 0) > 2 && track.codec?.toLowerCase() != 'ac3';
}
