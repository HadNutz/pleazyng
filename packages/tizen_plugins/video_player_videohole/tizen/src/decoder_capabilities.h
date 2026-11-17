// Query Samsung's installed media-codec service without requiring that service
// to load the player plugin on firmware where it is unavailable.
#pragma once
#include <media_codec.h>
#include <dlfcn.h>
#include <flutter/encodable_value.h>
#include <utility>

inline flutter::EncodableList TizenHardwareVideoDecoders() {
  flutter::EncodableList result;
  void* lib = dlopen("libcapi-media-codec.so.0", RTLD_NOW | RTLD_LOCAL);
  if (!lib) return result;
  auto create = reinterpret_cast<decltype(&mediacodec_create)>(dlsym(lib, "mediacodec_create"));
  auto destroy = reinterpret_cast<decltype(&mediacodec_destroy)>(dlsym(lib, "mediacodec_destroy"));
  auto support = reinterpret_cast<decltype(&mediacodec_get_supported_type)>(dlsym(lib, "mediacodec_get_supported_type"));
  mediacodec_h handle = nullptr;
  if (create && destroy && support && create(&handle) == 0) {
    const std::pair<mediacodec_codec_type_e, const char*> codecs[] = {
      {MEDIACODEC_H264, "h264"}, {MEDIACODEC_HEVC, "hevc"}, {MEDIACODEC_VP9, "vp9"},
      {MEDIACODEC_VP8, "vp8"}, {MEDIACODEC_MPEG2, "mpeg2video"}, {MEDIACODEC_MPEG4, "mpeg4"},
    };
    for (auto entry : codecs) {
      int flags = 0;
      if (support(handle, entry.first, false, &flags) == 0 && (flags & MEDIACODEC_SUPPORT_TYPE_HW))
        result.emplace_back(entry.second);
    }
    destroy(handle);
  }
  dlclose(lib);
  return result;
}
