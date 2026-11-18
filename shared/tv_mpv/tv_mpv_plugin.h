// Both TV embedders share the mpv session. LG can present compressed packets
// on its hardware plane; the texture path can use a V4L2 memory-to-memory decoder.
#pragma once

#include <dlfcn.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "include/mpv/client.h"
#include "include/mpv/render.h"

namespace pleazyng_tv {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;

struct Api {
  void* lib = dlopen("libpleazyng_tv_mpv.so", RTLD_NOW | RTLD_LOCAL);
  template <typename T>
  T symbol(const char* name) {
    if (!lib) throw std::runtime_error("TV mpv is unavailable");
    auto ptr = reinterpret_cast<T>(dlsym(lib, name));
    if (!ptr) throw std::runtime_error("TV mpv ABI mismatch");
    return ptr;
  }
#define TV_MPV_API(name) decltype(&mpv_##name) name = symbol<decltype(&mpv_##name)>("mpv_" #name)
  TV_MPV_API(create);
  TV_MPV_API(initialize);
  TV_MPV_API(set_option_string);
  TV_MPV_API(command);
  TV_MPV_API(get_property);
  TV_MPV_API(get_property_string);
  TV_MPV_API(set_property_string);
  TV_MPV_API(free);
  TV_MPV_API(wait_event);
  TV_MPV_API(terminate_destroy);
  TV_MPV_API(render_context_create);
  TV_MPV_API(render_context_set_update_callback);
  TV_MPV_API(render_context_update);
  TV_MPV_API(render_context_render);
  TV_MPV_API(render_context_free);
#undef TV_MPV_API
  int (*ndl_acquire)(const char*) = reinterpret_cast<int (*)(const char*)>(dlsym(lib, "mpv_pleazyng_ndl_acquire"));
  int (*ndl_status)() = reinterpret_cast<int (*)()>(dlsym(lib, "mpv_pleazyng_ndl_status"));
  void (*ndl_release)() = reinterpret_cast<void (*)()>(dlsym(lib, "mpv_pleazyng_ndl_release"));
  using OverlayCallback = void (*)(void*, const uint8_t*, int, int, int);
  using SetOverlay = void (*)(OverlayCallback, void*);
  SetOverlay ndl_overlay = reinterpret_cast<SetOverlay>(dlsym(lib, "mpv_pleazyng_ndl_overlay"));
  static Api& instance() {
    static Api api;
    return api;
  }
};

struct Picture {
  int w, h;
  size_t stride;
  std::unique_ptr<uint8_t, decltype(&std::free)> rgba{nullptr, std::free};
  Picture(int width, int height) : w(width), h(height), stride((size_t(w) * 4 + 63) & ~size_t(63)) {
    void* storage = nullptr;
    if (posix_memalign(&storage, 64, stride * h)) throw std::bad_alloc();
    rgba.reset(static_cast<uint8_t*>(storage));
  }
  void packForFlutter() {
    const size_t row = size_t(w) * 4;
    if (row != stride)
      for (int y = 1; y < h; ++y) std::memmove(rgba.get() + row * y, rgba.get() + stride * y, row);
  }
};
struct PictureSlot {
  std::mutex mutex;
  std::shared_ptr<const Picture> picture;
  // Tizen copies synchronously with glTexImage2D and omits the release
  // callback. Retain the front buffer through the next raster callback.
  std::shared_ptr<const Picture> presented;
  FlutterDesktopPixelBuffer front{};
};
struct PictureLease {
  std::shared_ptr<const Picture> picture;
  FlutterDesktopPixelBuffer buffer{};
  explicit PictureLease(std::shared_ptr<const Picture> p) : picture(std::move(p)) {
    buffer.buffer = picture->rgba.get();
    buffer.width = picture->w;
    buffer.height = picture->h;
    buffer.release_context = this;
    buffer.release_callback = [](void* self) { delete static_cast<PictureLease*>(self); };
  }
};

class Session {
 public:
  explicit Session(flutter::TextureRegistrar* registrar, bool synchronous_upload = false)
      : registrar_(registrar), api_(Api::instance()), synchronous_upload_(synchronous_upload) {}
  ~Session() {
    if (render_) api_.render_context_set_update_callback(render_, nullptr, nullptr);
    {
      std::lock_guard<std::mutex> lock(wake_mutex_);
      closing_ = true;
    }
    wake_.notify_one();
    if (worker_.joinable()) worker_.join();
    if (render_) api_.render_context_free(render_);
    if (core_) api_.terminate_destroy(core_);
    if (plane_) {
      api_.ndl_overlay(nullptr, nullptr);
      api_.ndl_release();
    }
    if (texture_id_ >= 0) {
#ifdef PLEAZYNG_TIZEN_EMBEDDER
      registrar_->UnregisterTexture(texture_id_, [keep = texture_] {});
#else
      registrar_->UnregisterTexture(texture_id_);
#endif
    }
  }
  int64_t open(const std::string& uri, const std::string& window, bool hardware, const std::string& fonts = {}) {
    core_ = api_.create();
    if (!core_) throw std::runtime_error("mpv create failed");
    plane_ = hardware && !window.empty() && api_.ndl_acquire && api_.ndl_status && api_.ndl_release &&
             api_.ndl_overlay && api_.ndl_acquire(window.c_str());
    for (const auto& option : std::map<std::string, std::string>{
             {"vo", plane_ ? "webos-ndl" : "libmpv"},
             {"hwdec", hardware ? "v4l2m2m-copy" : "no"},
             {"hwdec-codecs", "all"},
             {"pause", "yes"},
             {"keep-open", "yes"},
             {"config", "no"},
             {"input-default-bindings", "no"},
             {"terminal", "no"},
             {"audio-display", "no"}}) {
      check(api_.set_option_string(core_, option.first.c_str(), option.second.c_str()));
    }
    if (!fonts.empty()) {
      check(api_.set_option_string(core_, "sub-font-provider", "none"));
      check(api_.set_option_string(core_, "sub-fonts-dir", fonts.c_str()));
      check(api_.set_option_string(core_, "sub-font", "Go Noto Current-Regular"));
    }
    if (plane_) {
      check(api_.set_option_string(core_, "vd", "webos-ndl"));
      check(api_.set_option_string(core_, "framedrop", "no"));
      check(api_.set_option_string(core_, "hr-seek", "no"));
    }
    check(api_.initialize(core_));
    registerTexture();
    if (plane_) api_.ndl_overlay(&publishOverlay, this);
    const char* command[] = {"loadfile", uri.c_str(), nullptr};
    check(api_.command(core_, command));
    return plane_ ? -2 : texture_id_;
  }

  void registerTexture() {
    mpv_render_param setup[] = {{MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_SW)}, {}};
    if (!plane_) check(api_.render_context_create(&render_, core_, setup));
    auto slot = slot_;
    texture_ = std::make_shared<flutter::TextureVariant>(flutter::PixelBufferTexture(
        [slot, synchronous = synchronous_upload_](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
          std::lock_guard<std::mutex> lock(slot->mutex);
          if (!slot->picture) return nullptr;
          if (synchronous) {
            slot->presented = slot->picture;
            slot->front.buffer = slot->presented->rgba.get();
            slot->front.width = slot->presented->w;
            slot->front.height = slot->presented->h;
            return &slot->front;
          }
          return &(new PictureLease(slot->picture))->buffer;
        }));
    texture_id_ = registrar_->RegisterTexture(texture_.get());
    check(texture_id_ < 0 ? -1 : 0);
    if (plane_) return;
    worker_ = std::thread([this] { draw(); });
    api_.render_context_set_update_callback(
        render_, [](void* opaque) { static_cast<Session*>(opaque)->signal(); }, this);
  }

  Map state() {
    while (auto* event = api_.wait_event(core_, 0)) {
      if (event->event_id == MPV_EVENT_NONE) break;
      if (event->event_id == MPV_EVENT_FILE_LOADED) loaded_ = true;
      if (event->event_id == MPV_EVENT_END_FILE && event->data) {
        const auto* end = static_cast<mpv_event_end_file*>(event->data);
        if (end->reason == MPV_END_FILE_REASON_ERROR) failed_ = true;
      }
    }
    int w = int(number("dwidth")), h = int(number("dheight"));
    if (plane_) {
      const int status = api_.ndl_status();
      const auto codec = loaded_ ? prop("current-tracks/video/codec") : std::string();
      if (status < 0 || (loaded_ && (prop("vid") == "no" || (!codec.empty() && codec != "h264" && codec != "hevc" &&
                                                             codec != "vp9" && codec != "av1"))))
        failed_ = true;
      if (status > 0) rendered_ = true;
    } else if (w > 0 && h > 0) {
      // Keep texture allocations bounded on 32-bit TVs, including malformed
      // dimensions. UHD fits at source resolution. Native planes bypass RGBA.
      constexpr double max_pixels = 4096.0 * 2160.0;
      const double scale = std::min(1.0, std::sqrt(max_pixels / (double(w) * h)));
      const int fitted_w = std::max(1, int(w * scale)), fitted_h = std::max(1, int(h * scale));
      bool resized;
      {
        std::lock_guard<std::mutex> lock(wake_mutex_);
        resized = width_ != fitted_w || height_ != fitted_h;
        width_ = fitted_w;
        height_ = fitted_h;
        if (resized) redraw_ = true;
      }
      if (resized) signal();
    }
    return {
        {Value("ready"), Value(loaded_ && (!plane_ || rendered_.load()))},
        {Value("failed"), Value(failed_ || render_failed_.load())},
        {Value("overlayTexture"), Value(plane_ ? texture_id_ : int64_t(-1))},
        {Value("output"), Value(plane_ ? "webos-ndl" : "libmpv-texture")},
        {Value("hardwareDecoder"),
         Value(rendered_.load() ? (plane_ ? std::string("webos-ndl") : prop("hwdec-current")) : std::string())},
        {Value("outputWidth"), Value(plane_ ? w : width_)},
        {Value("outputHeight"), Value(plane_ ? h : height_)},
        {Value("width"), Value(w)},
        {Value("height"), Value(h)},
        {Value("duration"), Value(int64_t(number("duration") * 1000))},
        {Value("position"), Value(int64_t(number("time-pos") * 1000))},
        {Value("playing"), Value(loaded_ && !flag("pause") && !flag("eof-reached"))},
        {Value("frame"), Value(rendered_.load())},
        {Value("buffering"), Value(flag("paused-for-cache"))},
        {Value("ended"), Value(flag("eof-reached"))}};
  }

  List tracks() {
    List rows;
    const int count = int(number("track-list/count"));
    for (int i = 0; i < count; ++i) {
      const auto p = std::string("track-list/") + std::to_string(i) + "/";
      auto type = prop(p + "type");
      if (type != "audio" && type != "sub") continue;
      rows.emplace_back(
          Map{{Value("id"), Value(prop(p + "id"))},
              {Value("type"), Value(type == "audio" ? "audio" : "subtitle")},
              {Value("language"), Value(prop(p + "lang"))},
              {Value("title"), Value(prop(p + "title"))},
              {Value("selected"), Value(flag((p + "selected").c_str()))}});
    }
    return rows;
  }
  void set(const char* name, const std::string& value) { check(api_.set_property_string(core_, name, value.c_str())); }
  void seek(double seconds) {
    auto target = std::to_string(seconds);
    const char* args[] = {"seek", target.c_str(), plane_ ? "absolute+keyframes" : "absolute+exact", nullptr};
    check(api_.command(core_, args));
  }

 private:
  flutter::TextureRegistrar* registrar_;
  Api& api_;
  bool synchronous_upload_;
  mpv_handle* core_ = nullptr;
  mpv_render_context* render_ = nullptr;
  int64_t texture_id_ = -1;
  std::shared_ptr<flutter::TextureVariant> texture_;
  std::shared_ptr<PictureSlot> slot_ = std::make_shared<PictureSlot>();
  std::thread worker_;
  std::condition_variable wake_;
  std::mutex wake_mutex_;
  bool plane_ = false;
  bool pending_ = false, closing_ = false, redraw_ = false, loaded_ = false, failed_ = false;
  int width_ = 0, height_ = 0;
  std::atomic<bool> rendered_{false}, render_failed_{false};

  static void check(int rc) {
    if (rc < 0) throw std::runtime_error("TV mpv rejected the operation");
  }
  std::string prop(const std::string& name) {
    auto* raw = api_.get_property_string(core_, name.c_str());
    if (!raw) return {};
    std::string value(raw);
    api_.free(raw);
    return value;
  }
  double number(const char* name) {
    double value = 0;
    return api_.get_property(core_, name, MPV_FORMAT_DOUBLE, &value) >= 0 && std::isfinite(value) ? value : 0;
  }
  bool flag(const char* name) {
    int value = 0;
    return api_.get_property(core_, name, MPV_FORMAT_FLAG, &value) >= 0 && value;
  }
  static void publishOverlay(void* context, const uint8_t* bgra, int stride, int w, int h) noexcept {
    auto& session = *static_cast<Session*>(context);
    try {
      auto picture = std::make_shared<Picture>(bgra ? w : 1, bgra ? h : 1);
      auto* dst = picture->rgba.get();
      if (!bgra) std::memset(dst, 0, 4);
      for (int y = 0; bgra && y < h; ++y) {
        const auto* src = bgra + y * stride;
        for (int x = 0; x < w; ++x, src += 4, dst += 4) {
          dst[0] = src[2];
          dst[1] = src[1];
          dst[2] = src[0];
          dst[3] = src[3];
        }
      }
      {
        std::lock_guard<std::mutex> guard(session.slot_->mutex);
        session.slot_->picture = std::move(picture);
      }
      session.registrar_->MarkTextureFrameAvailable(session.texture_id_);
    } catch (...) {
      session.render_failed_ = true;
    }
  }

  void signal() {
    {
      std::lock_guard<std::mutex> lock(wake_mutex_);
      pending_ = true;
    }
    wake_.notify_one();
  }
  void draw() {
    try {
      for (;;) {
        std::unique_lock<std::mutex> lock(wake_mutex_);
        wake_.wait(lock, [this] { return pending_ || closing_; });
        if (closing_) return;
        int size[] = {width_, height_};
        const bool redraw = redraw_;
        pending_ = redraw_ = false;
        lock.unlock();
        auto updates = api_.render_context_update(render_);
        if (!size[0] || !size[1] || (!redraw && !(updates & MPV_RENDER_UPDATE_FRAME))) continue;
        auto picture = std::make_shared<Picture>(size[0], size[1]);
        size_t stride = picture->stride;
        char format[] = "rgba";
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_SW_SIZE, size},
            {MPV_RENDER_PARAM_SW_FORMAT, format},
            {MPV_RENDER_PARAM_SW_STRIDE, &stride},
            {MPV_RENDER_PARAM_SW_POINTER, picture->rgba.get()},
            {}};
        check(api_.render_context_render(render_, params));
        picture->packForFlutter();
        {
          std::lock_guard<std::mutex> slot_lock(slot_->mutex);
          slot_->picture = std::move(picture);
        }
        rendered_ = true;
        registrar_->MarkTextureFrameAvailable(texture_id_);
      }
    } catch (...) {
      render_failed_ = true;
    }
  }
};

class TvMpvPlugin : public flutter::Plugin {
 public:
  explicit TvMpvPlugin(flutter::PluginRegistrar* registrar, List (*hardware_codecs)() = nullptr)
      : textures_(registrar->texture_registrar()),
        channel_(
            registrar->messenger(), "org.snapetech.pleazyng/system_video",
            &flutter::StandardMethodCodec::GetInstance()) {
    channel_.SetMethodCallHandler([this, hardware_codecs](const auto& call, auto result) {
      try {
        if (call.method_name() == "hardwareVideoDecoders") {
          result->Success(Value(hardware_codecs ? hardware_codecs() : List{}));
          return;
        }
        const auto& map = std::get<Map>(*call.arguments());
        auto id = map.at(Value("id")).LongValue();
        const auto& method = call.method_name();
        if (method == "create") {
#ifdef PLEAZYNG_TIZEN_EMBEDDER
          auto session = std::make_unique<Session>(textures_, true);
#else
          auto session = std::make_unique<Session>(textures_);
#endif
          const auto window = map.find(Value("windowId"));
          const auto fonts = map.find(Value("fontDir"));
          const auto hardware = map.find(Value("hardwareDecoding"));
          auto texture = session->open(
              std::get<std::string>(map.at(Value("uri"))),
              window == map.end() ? std::string() : std::get<std::string>(window->second),
              hardware == map.end() || std::get<bool>(hardware->second),
              fonts == map.end() ? std::string() : std::get<std::string>(fonts->second));
          sessions_[id] = std::move(session);
          result->Success(Value(texture));
          return;
        }
        if (method == "dispose") {
          sessions_.erase(id);
          result->Success();
          return;
        }
        auto& s = *sessions_.at(id);
        if (method == "state") {
          result->Success(Value(s.state()));
          return;
        }
        if (method == "tracks") {
          result->Success(Value(s.tracks()));
          return;
        }
        if (method == "play" || method == "pause")
          s.set("pause", method == "pause" ? "yes" : "no");
        else {
          const auto& value = map.at(Value("value"));
          if (method == "subtitleDelay")
            s.set("sub-delay", std::get<std::string>(value));
          else if (method == "subtitleVisible")
            s.set("sub-visibility", std::get<std::string>(value));
          else if (method == "audio" || method == "subtitle")
            s.set(method == "audio" ? "aid" : "sid", std::get<std::string>(value));
          else if (method == "seek")
            s.seek(value.LongValue() / 1000.0);
          else if (method == "rate")
            s.set("speed", std::to_string(std::get<double>(value)));
          else if (method == "volume")
            s.set("volume", std::to_string(100 * std::get<double>(value)));
          else {
            result->NotImplemented();
            return;
          }
        }
        result->Success();
      } catch (const std::exception&) {
        result->Error("tv-mpv", "TV mpv could not complete the operation");
      }
    });
  }

 private:
  flutter::TextureRegistrar* textures_;
  flutter::MethodChannel<Value> channel_;
  std::map<int64_t, std::unique_ptr<Session>> sessions_;
};
}  // namespace pleazyng_tv
