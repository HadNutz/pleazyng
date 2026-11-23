import '../i18n/strings.g.dart';
import '../models/motion_processing_mode.dart';
import '../services/motion_processing_service.dart';

const _gpu = 'GPU';
const _npu = 'NPU';
const _videoToolbox = 'VideoToolbox';

extension MotionSmoothingLabels on MotionSmoothingCapabilities {
  String label(MotionProcessingMode mode) => switch (mode) {
    MotionProcessingMode.off => t.settings.motionSmoothingOff,
    MotionProcessingMode.mpv when mpvGpu => '${t.settings.motionSmoothingMpv} · $_gpu',
    MotionProcessingMode.mpv => t.settings.motionSmoothingMpv,
    MotionProcessingMode.neural when videoToolbox => '${t.settings.neuralInterpolation} · $_videoToolbox',
    MotionProcessingMode.neural when npu && gpu => '${t.settings.neuralInterpolation} · $_npu / $_gpu',
    MotionProcessingMode.neural when npu => '${t.settings.neuralInterpolation} · $_npu',
    MotionProcessingMode.neural when gpu => '${t.settings.neuralInterpolation} · $_gpu',
    MotionProcessingMode.neural => t.settings.neuralInterpolation,
  };

  String? description(MotionProcessingMode mode) => switch (mode) {
    MotionProcessingMode.off => t.settings.motionSmoothingOffDescription,
    MotionProcessingMode.mpv when mpvGpu => t.settings.motionSmoothingDescription,
    MotionProcessingMode.mpv => t.settings.motionSmoothingMpvDescription,
    MotionProcessingMode.neural when gpu && npu => t.settings.neuralInterpolationUnavailableDescription,
    MotionProcessingMode.neural => null,
  };
}

String neuralInterpolationPresetLabel(NeuralInterpolationPreset preset) => switch (preset) {
  NeuralInterpolationPreset.performance => t.settings.neuralInterpolationPresetPerformance,
  NeuralInterpolationPreset.balanced => t.settings.neuralInterpolationPresetBalanced,
  NeuralInterpolationPreset.quality => t.settings.neuralInterpolationPresetQuality,
};
