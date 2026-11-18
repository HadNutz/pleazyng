#include "system_video.h"

#include <gst/app/gstappsink.h>
#include <gst/video/video.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

struct VideoPixelsData {
  std::mutex mutex;
  GstSample* latest = nullptr;
  std::vector<uint8_t> output;
  ~VideoPixelsData() { if (latest) gst_sample_unref(latest); }
};

struct VideoPixels { FlPixelBufferTexture parent; VideoPixelsData* frame; };
struct VideoPixelsClass { FlPixelBufferTextureClass parent; };
G_DEFINE_TYPE(VideoPixels, video_pixels, fl_pixel_buffer_texture_get_type())

static gboolean copy_video_pixels(FlPixelBufferTexture* base, const uint8_t** buffer,
                                  uint32_t* width, uint32_t* height, GError**) {
  auto* frame = reinterpret_cast<VideoPixels*>(base)->frame;
  GstSample* sample;
  {
    std::lock_guard<std::mutex> lock(frame->mutex);
    sample = frame->latest ? gst_sample_ref(frame->latest) : nullptr;
  }
  if (!sample) return FALSE;
  GstVideoInfo info;
  GstVideoFrame mapped;
  bool ok = gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) &&
            gst_video_frame_map(&mapped, &info, gst_sample_get_buffer(sample), GST_MAP_READ);
  if (ok) {
    *width = GST_VIDEO_FRAME_WIDTH(&mapped);
    *height = GST_VIDEO_FRAME_HEIGHT(&mapped);
    const size_t row = size_t(*width) * 4;
    frame->output.resize(row * *height);
    auto* pixels = static_cast<uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&mapped, 0));
    const auto stride = GST_VIDEO_FRAME_PLANE_STRIDE(&mapped, 0);
    for (uint32_t y = 0; y < *height; ++y) {
      std::memcpy(frame->output.data() + row * y, pixels + stride * ptrdiff_t(y), row);
    }
    *buffer = frame->output.data();
    gst_video_frame_unmap(&mapped);
  }
  gst_sample_unref(sample);
  return ok;
}

static void video_pixels_class_init(VideoPixelsClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = copy_video_pixels;
  G_OBJECT_CLASS(klass)->finalize = [](GObject* o) {
    delete reinterpret_cast<VideoPixels*>(o)->frame;
    G_OBJECT_CLASS(video_pixels_parent_class)->finalize(o);
  };
}
static void video_pixels_init(VideoPixels* pixels) { pixels->frame = new VideoPixelsData; }

namespace {
bool isHardwareVideoDecoder(GstElementFactory* factory) {
  return factory && gst_element_factory_list_is_type(factory, GST_ELEMENT_FACTORY_TYPE_DECODER |
      GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO) &&
      gst_element_factory_list_is_type(factory, GST_ELEMENT_FACTORY_TYPE_HARDWARE);
}

// uridecodebin uses GValueArray for this signal even on current GStreamer.
G_GNUC_BEGIN_IGNORE_DEPRECATIONS
GValueArray* orderVideoDecoders(GstElement*, GstPad*, GstCaps*, GValueArray* factories, gpointer data) {
  const bool preferHardware = *static_cast<const bool*>(data);
  std::vector<const GValue*> video;
  std::vector<guint> slots;
  for (guint i = 0; i < factories->n_values; ++i) {
    auto* value = g_value_array_get_nth(factories, i);
    auto* factory = GST_ELEMENT_FACTORY(g_value_get_object(value));
    if (!gst_element_factory_list_is_type(factory, GST_ELEMENT_FACTORY_TYPE_DECODER | GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO)) continue;
    slots.push_back(i);
    video.push_back(value);
  }
  const auto isHardware = [](const GValue* value) {
    return isHardwareVideoDecoder(GST_ELEMENT_FACTORY(g_value_get_object(value)));
  };
  if (std::none_of(video.begin(), video.end(), isHardware)) return nullptr;
  auto* sorted = g_value_array_copy(factories);
  if (preferHardware) {
    // Preserve demuxer/parser positions and the driver's rank inside each group.
    std::stable_partition(video.begin(), video.end(), isHardware);
    for (size_t i = 0; i < video.size(); ++i)
      g_value_set_object(g_value_array_get_nth(sorted, slots[i]), g_value_get_object(video[i]));
  } else {
    for (size_t i = video.size(); i > 0; --i)
      if (isHardware(video[i - 1])) g_value_array_remove(sorted, slots[i - 1]);
  }
  return sorted;
}
G_GNUC_END_IGNORE_DEPRECATIONS

struct Session {
  FlTextureRegistrar* registrar;
  VideoPixels* pixels = nullptr;
  GstElement* pipeline = nullptr;
  GstElement* sink = nullptr;
  GstBus* bus = nullptr;
  guint timer = 0;
  bool prefer_hardware = true;
  std::atomic<bool> hardware_attempted{false};
  bool registered = false, failed = false, ready = false, ended = false, wants_play = false, buffering = false;
  int width = 0, height = 0;
  double rate = 1;

  explicit Session(FlTextureRegistrar* registrar) : registrar(registrar) {}
  ~Session() {
    if (timer) g_source_remove(timer);
    if (pipeline) gst_element_set_state(pipeline, GST_STATE_NULL);
    if (registered) fl_texture_registrar_unregister_texture(registrar, FL_TEXTURE(pixels));
    if (bus) gst_object_unref(bus);
    if (pipeline) gst_object_unref(pipeline);
    if (sink) gst_object_unref(sink);
    g_clear_object(&pixels);
  }

  bool open(const char* uri, bool hardware = true) {
    prefer_hardware = hardware;
    if (!gst_init_check(nullptr, nullptr, nullptr)) return false;
    pipeline = gst_element_factory_make("playbin", nullptr);
    sink = gst_element_factory_make("appsink", nullptr);
    if (!pipeline || !sink) return false;
    gst_object_ref_sink(sink);
    GstCaps* caps = gst_caps_from_string("video/x-raw,format=RGBA,pixel-aspect-ratio=1/1");
    g_object_set(sink, "caps", caps, "max-buffers", 2u, "drop", TRUE, "wait-on-eos", FALSE, nullptr);
    gst_caps_unref(caps);
    pixels = reinterpret_cast<VideoPixels*>(g_object_new(video_pixels_get_type(), nullptr));
    registered = fl_texture_registrar_register_texture(registrar, FL_TEXTURE(pixels));
    if (!registered) return false;
    g_signal_connect(pipeline, "element-setup", G_CALLBACK(+[](GstElement*, GstElement* child, gpointer data) {
      auto* self = static_cast<Session*>(data);
      auto* factory = gst_element_get_factory(child);
      if (!factory) return;
      if (isHardwareVideoDecoder(factory)) self->hardware_attempted = true;
      if (!strcmp(gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory)), "uridecodebin")) {
        g_signal_connect(child, "autoplug-sort", G_CALLBACK(orderVideoDecoders), &self->prefer_hardware);
      }
    }), this);
    g_object_set(pipeline, "uri", uri, "video-sink", sink, nullptr);
    bus = gst_element_get_bus(pipeline);
    auto change = gst_element_set_state(pipeline, GST_STATE_PAUSED);
    if (change == GST_STATE_CHANGE_FAILURE && !retryPreroll()) return false;
    if (change == GST_STATE_CHANGE_NO_PREROLL) ready = true;
    timer = g_timeout_add(12, [](gpointer data) -> gboolean {
      static_cast<Session*>(data)->tick();
      return G_SOURCE_CONTINUE;
    }, this);
    return true;
  }

  bool retryPreroll() {
    if (width || !prefer_hardware || !hardware_attempted) return false;
    // Finish streaming callbacks before changing the per-session selection.
    if (gst_element_set_state(pipeline, GST_STATE_NULL) == GST_STATE_CHANGE_FAILURE) return false;
    prefer_hardware = false;
    ready = false;
    failed = false;
    buffering = false;
    auto change = gst_element_set_state(pipeline, wants_play ? GST_STATE_PLAYING : GST_STATE_PAUSED);
    ready = change == GST_STATE_CHANGE_NO_PREROLL;
    return change != GST_STATE_CHANGE_FAILURE;
  }

  void tick() {
    while (GstMessage* msg = gst_bus_pop(bus)) {
      switch (GST_MESSAGE_TYPE(msg)) {
        case GST_MESSAGE_ERROR: {
          GError* error = nullptr;
          gst_message_parse_error(msg, &error, nullptr);
          const bool decodeError = error && error->domain == GST_STREAM_ERROR &&
              (error->code == GST_STREAM_ERROR_DECODE || error->code == GST_STREAM_ERROR_FORMAT);
          const bool fromHardware = GST_IS_ELEMENT(GST_MESSAGE_SRC(msg)) &&
              isHardwareVideoDecoder(gst_element_get_factory(GST_ELEMENT(GST_MESSAGE_SRC(msg))));
          failed = !((decodeError || fromHardware) && retryPreroll());
          g_clear_error(&error);
          break;
        }
        case GST_MESSAGE_EOS: ended = true; break;
        case GST_MESSAGE_STATE_CHANGED:
          if (GST_MESSAGE_SRC(msg) == GST_OBJECT(pipeline)) {
            GstState state;
            gst_message_parse_state_changed(msg, nullptr, &state, nullptr);
            if (state >= GST_STATE_PAUSED) ready = true;
          }
          break;
        case GST_MESSAGE_BUFFERING: {
          int percent;
          gst_message_parse_buffering(msg, &percent);
          buffering = percent < 100;
          if (wants_play) gst_element_set_state(pipeline, buffering ? GST_STATE_PAUSED : GST_STATE_PLAYING);
          break;
        }
        default: break;
      }
      gst_message_unref(msg);
    }
    GstSample* sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 0);
    if (!sample && !width) sample = gst_base_sink_get_last_sample(GST_BASE_SINK(sink));
    if (!sample) return;
    GstVideoInfo info;
    if (gst_video_info_from_caps(&info, gst_sample_get_caps(sample))) {
      width = info.width;
      height = info.height;
    }
    {
      std::lock_guard<std::mutex> lock(pixels->frame->mutex);
      if (pixels->frame->latest) gst_sample_unref(pixels->frame->latest);
      pixels->frame->latest = sample;
    }
    fl_texture_registrar_mark_texture_frame_available(registrar, FL_TEXTURE(pixels));
  }

  gint64 position() const {
    gint64 current = 0;
    gst_element_query_position(pipeline, GST_FORMAT_TIME, &current);
    return std::max<gint64>(0, current);
  }
  bool seek(gint64 ns, double speed) {
    if (!gst_element_seek(pipeline, speed, GST_FORMAT_TIME,
                          GstSeekFlags(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE),
                          GST_SEEK_TYPE_SET, ns, GST_SEEK_TYPE_NONE, GST_CLOCK_TIME_NONE)) return false;
    rate = speed;
    ended = false;
    return true;
  }
  FlValue* state() const {
    auto* out = fl_value_new_map();
    gint64 duration = 0;
    gst_element_query_duration(pipeline, GST_FORMAT_TIME, &duration);
    fl_value_set_string_take(out, "ready", fl_value_new_bool(ready));
    fl_value_set_string_take(out, "failed", fl_value_new_bool(failed));
    fl_value_set_string_take(out, "ended", fl_value_new_bool(ended));
    fl_value_set_string_take(out, "playing", fl_value_new_bool(wants_play && !buffering && !ended));
    fl_value_set_string_take(out, "buffering", fl_value_new_bool(buffering));
    fl_value_set_string_take(out, "frame", fl_value_new_bool(width > 0));
    fl_value_set_string_take(out, "duration", fl_value_new_int(std::max<gint64>(0, duration) / GST_MSECOND));
    fl_value_set_string_take(out, "position", fl_value_new_int(position() / GST_MSECOND));
    fl_value_set_string_take(out, "width", fl_value_new_int(width));
    fl_value_set_string_take(out, "height", fl_value_new_int(height));
    return out;
  }

  FlValue* tracks() const {
    auto* out = fl_value_new_list();
    guint flags;
    g_object_get(pipeline, "flags", &flags, nullptr);
    for (bool audio : {true, false}) {
      int count = 0, selected = -1;
      g_object_get(pipeline, audio ? "n-audio" : "n-text", &count,
                   audio ? "current-audio" : "current-text", &selected, nullptr);
      for (int i = 0; i < count; ++i) {
        auto* row = fl_value_new_map();
        GstTagList* tags = nullptr;
        g_signal_emit_by_name(pipeline, audio ? "get-audio-tags" : "get-text-tags", i, &tags);
        if (tags) {
          g_autofree gchar* lang = nullptr;
          if (gst_tag_list_get_string(tags, GST_TAG_LANGUAGE_CODE, &lang))
            fl_value_set_string_take(row, "language", fl_value_new_string(lang));
          gst_tag_list_unref(tags);
        }
        fl_value_set_string_take(row, "id", fl_value_new_string(std::to_string(i).c_str()));
        fl_value_set_string_take(row, "type", fl_value_new_string(audio ? "audio" : "subtitle"));
        fl_value_set_string_take(row, "selected", fl_value_new_bool(i == selected && (audio || (flags & 4u))));
        fl_value_append_take(out, row);
      }
    }
    return out;
  }
};

FlValue* decoderInventory() {
  if (!gst_init_check(nullptr, nullptr, nullptr)) return fl_value_new_null();
  auto* result = fl_value_new_map();
  auto* video = fl_value_new_list();
  auto* hardware = fl_value_new_list();
  auto* containers = fl_value_new_list();
  fl_value_set_string_take(result, "video", video);
  fl_value_set_string_take(result, "hardware", hardware);
  fl_value_set_string_take(result, "containers", containers);
  auto* decoders = gst_element_factory_list_get_elements(GST_ELEMENT_FACTORY_TYPE_DECODER |
      GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO, GST_RANK_MARGINAL);
  auto* demuxers = gst_element_factory_list_get_elements(GST_ELEMENT_FACTORY_TYPE_DEMUXER, GST_RANK_MARGINAL);
  struct Format { const char* id; const char* caps; };
  const Format codecs[] = {{"h264", "video/x-h264"}, {"hevc", "video/x-h265"}, {"av1", "video/x-av1"},
      {"vp9", "video/x-vp9"}, {"vp8", "video/x-vp8"}, {"mpeg2video", "video/mpeg,mpegversion=(int)2,systemstream=(boolean)false"},
      {"mpeg4", "video/mpeg,mpegversion=(int)4,systemstream=(boolean)false"}};
  const Format formats[] = {{"mp4", "video/quicktime,variant=(string)iso"}, {"mkv", "video/x-matroska"},
      {"webm", "video/webm"}, {"mpegts", "video/mpegts,systemstream=(boolean)true"}};
  auto matches = [](GList* factories, const char* type) {
    GstCaps* caps = gst_caps_from_string(type);
    GList* found = gst_element_factory_list_filter(factories, caps, GST_PAD_SINK, FALSE);
    gst_caps_unref(caps);
    return found;
  };
  for (auto entry : codecs) {
    GList* found = matches(decoders, entry.caps);
    if (found) fl_value_append_take(video, fl_value_new_string(entry.id));
    for (GList* node = found; node; node = node->next) {
      if (gst_element_factory_list_is_type(GST_ELEMENT_FACTORY(node->data), GST_ELEMENT_FACTORY_TYPE_HARDWARE)) {
        fl_value_append_take(hardware, fl_value_new_string(entry.id));
        break;
      }
    }
    gst_plugin_feature_list_free(found);
  }
  for (auto entry : formats) {
    GList* found = matches(demuxers, entry.caps);
    if (found) fl_value_append_take(containers, fl_value_new_string(entry.id));
    gst_plugin_feature_list_free(found);
  }
  gst_plugin_feature_list_free(decoders);
  gst_plugin_feature_list_free(demuxers);
  return result;
}

struct Host {
  FlTextureRegistrar* registrar;
  std::map<int64_t, std::unique_ptr<Session>> sessions;
};

void handle(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* host = static_cast<Host*>(data);
  if (!strcmp(fl_method_call_get_name(call), "decoderInventory")) {
    g_autoptr(FlValue) inventory = decoderInventory();
    fl_method_call_respond_success(call, inventory, nullptr);
    return;
  }
  auto* args = fl_method_call_get_args(call);
  auto* key = fl_value_lookup_string(args, "id");
  auto* value = fl_value_lookup_string(args, "value");
  const std::string method = fl_method_call_get_name(call);
  g_autoptr(FlValue) reply = nullptr;
  bool ok = key && fl_value_get_type(key) == FL_VALUE_TYPE_INT;
  if (ok) {
    const auto id = fl_value_get_int(key);
    if (method == "create") {
      auto session = std::make_unique<Session>(host->registrar);
      auto* uri = fl_value_lookup_string(args, "uri");
      auto* hardware = fl_value_lookup_string(args, "hardwareDecoding");
      ok = uri && session->open(fl_value_get_string(uri), !hardware || fl_value_get_bool(hardware));
      if (ok) {
        reply = fl_value_new_int(fl_texture_get_id(FL_TEXTURE(session->pixels)));
        host->sessions[id] = std::move(session);
      }
    } else if (method == "dispose") {
      host->sessions.erase(id);
    } else if (host->sessions.count(id)) {
      auto& s = *host->sessions.at(id);
      if (method == "state") reply = s.state();
      else if (method == "tracks") reply = s.tracks();
      else if (method == "play" || method == "pause") {
        s.wants_play = method == "play";
        ok = gst_element_set_state(s.pipeline, s.wants_play && !s.buffering ? GST_STATE_PLAYING : GST_STATE_PAUSED)
              != GST_STATE_CHANGE_FAILURE;
      } else if (method == "volume") g_object_set(s.pipeline, "volume", fl_value_get_float(value), nullptr);
      else if (method == "rate") ok = s.seek(s.position(), fl_value_get_float(value));
      else if (method == "seek") ok = s.seek(fl_value_get_int(value) * GST_MSECOND, s.rate);
      else if (method == "audio" || method == "subtitle") {
        const char* selection = fl_value_get_string(value);
        const bool enabled = strcmp(selection, "no") != 0;
        if (method == "subtitle") {
          guint flags;
          g_object_get(s.pipeline, "flags", &flags, nullptr);
          g_object_set(s.pipeline, "flags", enabled ? flags | 4u : flags & ~4u, nullptr);
        }
        if (enabled) g_object_set(s.pipeline, method == "audio" ? "current-audio" : "current-text",
                                  static_cast<int>(g_ascii_strtoll(selection, nullptr, 10)), nullptr);
      } else { fl_method_call_respond_not_implemented(call, nullptr); return; }
    } else ok = false;
  }
  if (ok) fl_method_call_respond_success(call, reply, nullptr);
  else fl_method_call_respond_error(call, "gstreamer", "GStreamer rejected the operation", nullptr, nullptr);
}
}  // namespace

void register_system_video(FlPluginRegistrar* registrar) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
      "org.snapetech.pleazyng/system_video", FL_METHOD_CODEC(codec));
  auto* host = new Host{fl_plugin_registrar_get_texture_registrar(registrar), {}};
  fl_method_channel_set_method_call_handler(channel, handle, host, [](gpointer data) { delete static_cast<Host*>(data); });
}
