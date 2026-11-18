// Query Samsung's installed media-codec service without requiring that service
// to load the player plugin on firmware where it is unavailable.
#pragma once
// Common TV SDKs differ in whether they ship the low-level service headers.
// The stable C ABI below is sufficient to call the runtime probe. Check its
// constants at compile time when the full Tizen multimedia SDK is present.
#if __has_include(<media_codec.h>) && __has_include(<tbm_surface.h>) && __has_include(<tbm_type.h>)
#include <media_codec.h>
static_assert(MEDIACODEC_H264 == 0x2030 && MEDIACODEC_HEVC == 0x2080 &&
              MEDIACODEC_VP9 == 0x20a0 && MEDIACODEC_SUPPORT_TYPE_HW == 4);
#endif
#include <dlfcn.h>
#include <flutter/encodable_value.h>
#include <utility>

inline flutter::EncodableList TizenHardwareVideoDecoders() {
  flutter::EncodableList result;
  void* lib = dlopen("libcapi-media-codec.so.0", RTLD_NOW | RTLD_LOCAL);
  if (!lib) return result;
  auto create = reinterpret_cast<int (*)(void**)>(dlsym(lib, "mediacodec_create"));
  auto destroy = reinterpret_cast<int (*)(void*)>(dlsym(lib, "mediacodec_destroy"));
  auto support = reinterpret_cast<int (*)(void*, int, bool, int*)>(dlsym(lib, "mediacodec_get_supported_type"));
  void* handle = nullptr;
  if (create && destroy && support && create(&handle) == 0) {
    const std::pair<int, const char*> codecs[] = {
      {0x2030, "h264"}, {0x2080, "hevc"}, {0x20a0, "vp9"},
      {0x2090, "vp8"}, {0x2060, "mpeg2video"}, {0x2070, "mpeg4"},
    };
    for (auto entry : codecs) {
      int flags = 0;
      if (support(handle, entry.first, false, &flags) == 0 && (flags & 4))
        result.emplace_back(entry.second);
    }
    destroy(handle);
  }
  dlclose(lib);
  return result;
}
