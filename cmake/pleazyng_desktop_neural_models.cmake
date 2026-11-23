# Stage the two larger ANVIL ONNX graphs only in Windows/Linux desktop bundles.
# Flutter's desktop AssetBundle reads exact keys from data/flutter_assets even
# when those files are not in pubspec.yaml, so mobile and TV bundles stay small.
set(PLEAZYNG_DESKTOP_NEURAL_MODEL_SOURCE_DIR
  "${CMAKE_CURRENT_LIST_DIR}/../assets/motion_models/desktop")

macro(_pleazyng_install_desktop_neural_model filename bytes sha256 install_data_dir)
  set(model_root "$ENV{PLEAZYNG_DESKTOP_NEURAL_MODEL_ROOT}")
  if(model_root STREQUAL "")
    set(model_root "${PLEAZYNG_DESKTOP_NEURAL_MODEL_SOURCE_DIR}")
  endif()
  file(TO_CMAKE_PATH "${model_root}" model_root)
  set(model_source "${model_root}/${filename}")
  if(NOT EXISTS "${model_source}")
    message(FATAL_ERROR "Pinned ANVIL model is missing: ${model_source}")
  endif()

  file(SIZE "${model_source}" model_source_size)
  file(SHA256 "${model_source}" model_source_sha256)
  if(NOT "${model_source_size}" STREQUAL "${bytes}" OR
     NOT "${model_source_sha256}" STREQUAL "${sha256}")
    message(FATAL_ERROR "Pinned ANVIL model failed its size/SHA-256 check: ${filename}")
  endif()

  set(installed_model
    "${install_data_dir}/flutter_assets/assets/motion_models/${filename}")
  install(CODE "file(REMOVE \"${installed_model}\")" COMPONENT Runtime)
  install(FILES "${model_source}"
    DESTINATION "${install_data_dir}/flutter_assets/assets/motion_models"
    COMPONENT Runtime)
endmacro()

macro(pleazyng_install_desktop_neural_models install_data_dir)
  _pleazyng_install_desktop_neural_model(
    "D_unet_v3bs_nomv_1080p.onnx"
    3441349
    "65e871aed25b331e3a3747cf9019942121a94af71997476f5804a24b768cd0d8"
    "${install_data_dir}")
  _pleazyng_install_desktop_neural_model(
    "D_unet_v3bm_nomv_1080p.onnx"
    10677524
    "261f95a17c865b45e4d7e2be3439d91b47315bef96e32d46f3cfc785941774fd"
    "${install_data_dir}")
endmacro()
