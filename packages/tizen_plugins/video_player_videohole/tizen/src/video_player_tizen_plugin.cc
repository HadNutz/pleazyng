// Copyright 2022 Samsung Electronics Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#define PLEAZYNG_TIZEN_EMBEDDER 1
#include "../../../../../shared/tv_mpv/tv_mpv_plugin.h"
#include "video_player_tizen_plugin.h"
#include "decoder_capabilities.h"

#include <flutter/plugin_registrar.h>
#include <flutter_tizen.h>

#include <memory>

#include "ffi_messages.h"
#include "log.h"
#include "visualizer_host.h"

namespace video_player_videohole_tizen {

class VideoPlayerTizenPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      FlutterDesktopPluginRegistrarRef registrar_ref,
      flutter::PluginRegistrar* plugin_registrar) {
    auto plugin = std::make_unique<VideoPlayerTizenPlugin>(registrar_ref);
    plugin_registrar->AddPlugin(std::move(plugin));
  plugin_registrar->AddPlugin(std::make_unique<pleazyng_tv::TvMpvPlugin>(plugin_registrar, TizenHardwareVideoDecoders));
  }

  explicit VideoPlayerTizenPlugin(
      FlutterDesktopPluginRegistrarRef registrar_ref)
      : registrar_ref_(registrar_ref) {
    auto* plugin_registrar =
        flutter::PluginRegistrarManager::GetInstance()
            ->GetRegistrar<flutter::PluginRegistrar>(registrar_ref);
    ffi_set_plugin_registrar(registrar_ref, plugin_registrar);
    visualizer_ = std::make_unique<VisualizerHost>(plugin_registrar);

    LOG_INFO("[VideoPlayerTizenPlugin] Registered with registrar");
  }

  ~VideoPlayerTizenPlugin() override {
    LOG_INFO(
        "[VideoPlayerTizenPlugin] Destroying plugin, cleaning up resources");
    visualizer_.reset();
    ffi_dispose_all_players();
  }

  VideoPlayerTizenPlugin(const VideoPlayerTizenPlugin&) = delete;
  VideoPlayerTizenPlugin& operator=(const VideoPlayerTizenPlugin&) = delete;

 private:
  FlutterDesktopPluginRegistrarRef registrar_ref_;
  std::unique_ptr<VisualizerHost> visualizer_;
};

extern "C" {

void VideoPlayerTizenPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar_ref) {
  auto* plugin_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrar>(registrar_ref);

  VideoPlayerTizenPlugin::RegisterWithRegistrar(registrar_ref,
                                                plugin_registrar);
}

}  // extern "C"

}  // namespace video_player_videohole_tizen
