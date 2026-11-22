part of '../settings_service.dart';

/// Reads the pre-release motion smoothing profiles as the single supported
/// MPV mode, so preferences created during development keep their intent.
class _MotionProcessingModePref extends EnumPref<MotionProcessingMode> {
  const _MotionProcessingModePref()
    : super('motion_smoothing_preset', values: MotionProcessingMode.values, defaultValue: MotionProcessingMode.off);

  @override
  MotionProcessingMode fromJson(Object? value) => switch (value) {
    'natural' || 'balanced' || 'smooth' => MotionProcessingMode.mpv,
    _ => super.fromJson(value),
  };

  @override
  MotionProcessingMode readFrom(BaseSharedPreferencesService svc) => switch (svc.readNullableString(key)) {
    'natural' || 'balanced' || 'smooth' => MotionProcessingMode.mpv,
    _ => super.readFrom(svc),
  };
}
