import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/motion_processing_mode.dart';
import 'package:plezy/services/motion_processing_service.dart';
import 'package:plezy/widgets/motion_smoothing_labels.dart';

void main() {
  test('non-MPV backends only offer Off and native TV MPV only offers its mixer', () async {
    for (final backend in ['exoplayer', 'mediafoundation', 'gstreamer', 'avplayer']) {
      expect((await MotionSmoothingCapabilities.detect(backend)).modes, [MotionProcessingMode.off]);
    }
    expect(await MotionSmoothingCapabilities.detect('tvmpv').then((capabilities) => capabilities.modes), [
      MotionProcessingMode.off,
      MotionProcessingMode.mpv,
    ]);
  });

  test('desktop provider libraries alone do not advertise an NPU', () async {
    final sysClass = await Directory.systemTemp.createTemp('pleazyng-motion-hardware-test-');
    addTearDown(() => sysClass.delete(recursive: true));
    const manifest = 'OpenVINOExecutionProvider\tNPU\topenvino.so\nWebGpuExecutionProvider\tGPU\twebgpu.so';
    Future<void> driver(String node, String name) async {
      final target = await Directory('${sysClass.path}/drivers/$name').create(recursive: true);
      await Directory('${sysClass.path}/$node/device').create(recursive: true);
      await Link('${sysClass.path}/$node/device/driver').create(target.path);
    }

    expect(await MotionSmoothingCapabilities.linuxMotionAccelerators(sysClass, manifest), (gpu: false, npu: false));
    await driver('drm/renderD128', 'amdgpu');
    expect(await MotionSmoothingCapabilities.linuxMotionAccelerators(sysClass, manifest), (gpu: true, npu: false));
    await driver('accel/accel0', 'amdxdna');
    expect(await MotionSmoothingCapabilities.linuxMotionAccelerators(sysClass, manifest), (gpu: true, npu: false));
    await driver('accel/accel1', 'intel_vpu');
    expect(await MotionSmoothingCapabilities.linuxMotionAccelerators(sysClass, manifest), (gpu: true, npu: true));
  }, skip: !Platform.isLinux);

  test('Android options require a usable model path and device-specific NPU evidence', () {
    expect(
      MotionSmoothingCapabilities.androidMotionAccelerators({
        'litertModelManifestPresent': true,
        'litertGpuAvailable': true,
        'gpuHardwareAvailable': true,
        'litertNpuProviders': ['intel-openvino'],
      }),
      (gpu: true, npu: false),
    );
    expect(
      MotionSmoothingCapabilities.androidMotionAccelerators({
        'qnnHtpAvailable': true,
        'anvilContextIds': ['anvil-s-1080p'],
      }),
      (gpu: false, npu: true),
    );
    expect(MotionSmoothingCapabilities.androidMotionAccelerators({'litertGpuAvailable': true}), (
      gpu: false,
      npu: false,
    ));
  });

  test('the automatic accelerator choice names only supported hardware', () {
    const desktop = MotionSmoothingCapabilities(mpv: true, gpu: true);
    expect(desktop.modes, [MotionProcessingMode.off, MotionProcessingMode.mpv, MotionProcessingMode.neural]);
    expect(desktop.label(MotionProcessingMode.neural), endsWith('GPU'));
    expect(desktop.label(MotionProcessingMode.neural), isNot(contains('NPU')));
    expect(const MotionSmoothingCapabilities(npu: true).label(MotionProcessingMode.neural), endsWith('NPU'));
    expect(
      const MotionSmoothingCapabilities(gpu: true, npu: true).label(MotionProcessingMode.neural),
      endsWith('NPU / GPU'),
    );
  });

  test('Apple labels the GPU mixer and VideoToolbox synthesis separately', () {
    const apple = MotionSmoothingCapabilities(mpv: true, mpvGpu: true, videoToolbox: true);
    expect(apple.modes, [MotionProcessingMode.off, MotionProcessingMode.mpv, MotionProcessingMode.neural]);
    expect(apple.label(MotionProcessingMode.mpv), endsWith('GPU'));
    expect(apple.label(MotionProcessingMode.neural), endsWith('VideoToolbox'));
    expect(apple.npu, isFalse);
  });
}
