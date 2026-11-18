// Open the packaged runtime on the target or under an ABI emulator and verify
// that a supplied solid-red video actually decodes through libmpv's SW API.
#include "../../shared/tv_mpv/include/mpv/render.h"
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  assert(argc == 3 || argc == 4);
  void *lib = dlopen(argv[1], RTLD_NOW);
  if (!lib) { fprintf(stderr, "%s\n", dlerror()); return 1; }
#define LOAD(fn) __typeof__(&mpv_##fn) fn = dlsym(lib, "mpv_" #fn); assert(fn)
  LOAD(create); LOAD(initialize); LOAD(set_option_string); LOAD(command);
  LOAD(render_context_create); LOAD(render_context_render); LOAD(render_context_update);
  LOAD(render_context_free); LOAD(terminate_destroy); LOAD(wait_event);
  mpv_handle *ctx = create();
  assert(ctx);
  assert(set_option_string(ctx, "vo", "libmpv") == 0);
  assert(set_option_string(ctx, "ao", "null") == 0);
  assert(set_option_string(ctx, "pause", argc == 4 ? "no" : "yes") == 0);
  if (argc == 4) {
    assert(set_option_string(ctx, "sid", "1") == 0);
    assert(set_option_string(ctx, "sub-font-provider", "none") == 0);
    assert(set_option_string(ctx, "sub-fonts-dir", argv[3]) == 0);
    assert(set_option_string(ctx, "sub-font", "Go Noto Current-Regular") == 0);
  }
  assert(initialize(ctx) == 0);
  mpv_render_context *rc = NULL;
  mpv_render_param setup[] = {{MPV_RENDER_PARAM_API_TYPE, "sw"}, {0}};
  assert(render_context_create(&rc, ctx, setup) == 0);
  const char *cmd[] = {"loadfile", argv[2], NULL};
  assert(command(ctx, cmd) == 0);
  int ok = 0, size[] = {160, 90};
  static unsigned char pixels[160 * 90 * 4] __attribute__((aligned(64)));
  size_t stride = 160 * 4;
  mpv_render_param params[] = {{MPV_RENDER_PARAM_SW_SIZE, size}, {MPV_RENDER_PARAM_SW_FORMAT, "rgba"},
    {MPV_RENDER_PARAM_SW_STRIDE, &stride}, {MPV_RENDER_PARAM_SW_POINTER, pixels}, {0}};
  int saw_cue = 0;
  for (int i = 0; i < 2000 && !ok; ++i) {
    mpv_event* event = wait_event(ctx, 0.005);
    if (event->event_id == MPV_EVENT_END_FILE) break;
    if (render_context_update(rc) & MPV_RENDER_UPDATE_FRAME) {
      assert(render_context_render(rc, params) == 0);
      const unsigned char *p = pixels + (160 * 45 + 80) * 4;
      int red = p[0] > 200 && p[1] < 50 && p[2] < 50 && p[3] == 255;
      if (argc == 3) {
        ok = red;
      } else {
        int glyph = 0;
        for (size_t j = 0; j < sizeof(pixels); j += 4)
          if (pixels[j+1] > 64 && pixels[j+2] > 64) { glyph = 1; break; }
        if (red && saw_cue && !glyph) ok = 1;
        if (glyph) saw_cue = 1;
      }
    }
  }
  render_context_free(rc);
  terminate_destroy(ctx);
  dlclose(lib);
  puts(!ok ? "No matching frame" : argc == 4 ? "Rendered and cleared embedded subtitle on red video" : "Decoded opaque red RGBA frame");
  return ok ? 0 : 1;
}
