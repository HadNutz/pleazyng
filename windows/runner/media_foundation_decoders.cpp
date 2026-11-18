#include "media_foundation_decoders.h"

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>

namespace {
// Windows N can lack Media Foundation. Load it only when the profile is probed.
struct MediaFoundation {
  HMODULE module = LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  template<class T> T symbol(const char* name) const {
    return module ? reinterpret_cast<T>(GetProcAddress(module, name)) : nullptr;
  }
  decltype(&MFStartup) start = symbol<decltype(&MFStartup)>("MFStartup");
  decltype(&MFShutdown) stop = symbol<decltype(&MFShutdown)>("MFShutdown");
  decltype(&MFTEnumEx) enumerate = symbol<decltype(&MFTEnumEx)>("MFTEnumEx");
  bool ready = start && stop && enumerate && SUCCEEDED(start(MF_VERSION, MFSTARTUP_FULL));
  ~MediaFoundation() {
    if (ready) stop();
    if (module) FreeLibrary(module);
  }

  bool hasDecoder(const GUID& subtype, UINT32 flags) const {
    MFT_REGISTER_TYPE_INFO input{MFMediaType_Video, subtype};
    IMFActivate** matches = nullptr;
    UINT32 count = 0;
    const auto hr = enumerate(MFT_CATEGORY_VIDEO_DECODER, flags | MFT_ENUM_FLAG_SORTANDFILTER,
                              &input, nullptr, &matches, &count);
    for (UINT32 i = 0; i < count; ++i) matches[i]->Release();
    CoTaskMemFree(matches);
    return SUCCEEDED(hr) && count > 0;
  }
};
}  // namespace

flutter::EncodableValue MediaFoundationDecoderInventory() {
  MediaFoundation mf;
  if (!mf.ready) return flutter::EncodableValue();
  flutter::EncodableList video, hardware;
  struct Codec { const char* name; const GUID& subtype; };
  const Codec codecs[] = {{"h264", MFVideoFormat_H264}, {"hevc", MFVideoFormat_HEVC},
                          {"av1", MFVideoFormat_AV1}, {"vp9", MFVideoFormat_VP90}};
  for (const auto& codec : codecs) {
    const bool accelerated = mf.hasDecoder(codec.subtype, MFT_ENUM_FLAG_HARDWARE);
    if (accelerated) hardware.emplace_back(codec.name);
    if (accelerated || mf.hasDecoder(codec.subtype, MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT))
      video.emplace_back(codec.name);
  }
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("video"), flutter::EncodableValue(std::move(video))},
      {flutter::EncodableValue("hardware"), flutter::EncodableValue(std::move(hardware))}});
}
