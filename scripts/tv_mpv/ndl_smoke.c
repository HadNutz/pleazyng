// SPDX-License-Identifier: LGPL-2.1-or-later
// Build twice with the LG NDK: as a test NDL .so (-DMOCK_NDL), and as a
// client. The client exercises the real mpv decoder and video-output modules.
// The mock captures what the board decoder would receive for offline decoding.
#ifdef MOCK_NDL
#include <NDL/NDL_directmedia.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static FILE *out, *timestamps;
static NDL_DIRECTVIDEO_SRC_TYPE source;
bool NDL_DirectMedia_DL_Initialize(void) { return true; }
int NDL_DirectMediaSetWindowId(const char *id) { return strcmp(id, "test-window"); }
int NDL_DirectMediaInit(const char *app) { return strcmp(app, "org.snapetech.pleazyng"); }
int NDL_DirectMediaSetAppState(NDL_DIRECTMEDIA_APP_STATE s) { return 0; }
int NDL_DirectMediaLoad(NDL_DIRECTMEDIA_DATA_INFO_T *m, StateCallbackFP cb) {
    source = m->videoDataInfo.source;
    if (source != NDL_DIRECTVIDEO_SRC_TYPE_H264 && source != NDL_DIRECTVIDEO_SRC_TYPE_HEVC &&
        source != NDL_DIRECTVIDEO_SRC_TYPE_VP9) return -1;
    const char *path = getenv("NDL_PTS_CAPTURE");
    if (path && !(timestamps = fopen(path, "w"))) return -1;
    out = fopen(getenv("NDL_CAPTURE"), "wb");
    return out ? 0 : -1;
}
int NDL_DirectMediaUnload(void) {
    if (out) fclose(out);
    if (timestamps) fclose(timestamps);
    out = timestamps = NULL;
    return 0;
}
int NDL_DirectMediaQuit(void) { return 0; }
int NDL_DirectVideoSetArea(int x, int y, int w, int h) {
    return w == atoi(getenv("NDL_WIDTH")) && h == atoi(getenv("NDL_HEIGHT")) ? 0 : -1;
}
int NDL_DirectVideoSetHDRInfo(NDL_DIRECTVIDEO_HDR_INFO_T hdr) {
    const char *path = getenv("NDL_HDR_CAPTURE");
    if (!path) return -1;
    FILE *file = fopen(path, "w");
    if (!file) return -1;
    fprintf(file, "%u %u %u\n", hdr.colorPrimaries, hdr.transferCharacteristics, hdr.matrixCoeffs);
    return fclose(file);
}
int NDL_DirectVideoPlay(void *data, unsigned size, long long pts) {
    const unsigned char *p = data;
    if (source != NDL_DIRECTVIDEO_SRC_TYPE_VP9 &&
        (size < 4 || p[0] || p[1] || (p[2] != 1 && (p[2] || p[3] != 1)))) return -1;
    if (timestamps && fprintf(timestamps, "%lld\n", pts) < 0) return -1;
    return fwrite(data, 1, size, out) == size ? 0 : -1;
}
int NDL_DirectVideoFlushRenderBuffer(void) { return 0; }
#else
#include "../../shared/tv_mpv/include/mpv/client.h"
#include <assert.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <dlfcn.h>
#include <stdio.h>
// With a font directory and an embedded subtitle fixture, require actual
// nontransparent glyph pixels and their removal during the following cue gap.
typedef void (*overlay_cb)(void *, const uint8_t *, int, int, int);
static atomic_int visible, cleared;
static void observe_overlay(void *ctx, const uint8_t *bgra, int stride, int w, int h) {
    if (!bgra) {
        if (atomic_load(&visible)) atomic_store(&cleared, 1);
        return;
    }
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
            if (bgra[y * stride + 4 * x + 3]) { atomic_store(&visible, 1); return; }
}
int main(int argc, char **argv) {
    assert(argc == 3 || argc == 4);
    void *so = dlopen(argv[1], RTLD_NOW);
    if (!so) { fprintf(stderr, "%s\n",dlerror()); return 1; }
#define FN(f) __typeof__(&mpv_##f) f = dlsym(so, "mpv_" #f); assert(f)
    FN(create); FN(initialize); FN(command); FN(set_option_string); FN(wait_event);
    FN(terminate_destroy); FN(request_log_messages);
    int (*acquire)(const char *) = dlsym(so, "mpv_pleazyng_ndl_acquire");
    int (*status)(void) = dlsym(so, "mpv_pleazyng_ndl_status");
    void (*release)(void) = dlsym(so, "mpv_pleazyng_ndl_release");
    assert(acquire && release && status && acquire("test-window"));
    assert(!acquire("second-window"));
    void (*overlay)(overlay_cb, void *) = dlsym(so, "mpv_pleazyng_ndl_overlay");
    assert(overlay);
    if (argc == 4) overlay(observe_overlay, NULL);
    mpv_handle *mp = create();
    if (argc == 4) {
        assert(set_option_string(mp, "sid", "1") == 0);
        assert(set_option_string(mp, "sub-font-provider", "none") == 0);
        assert(set_option_string(mp, "sub-fonts-dir", argv[3]) == 0);
        assert(set_option_string(mp, "sub-font", "Go Noto Current-Regular") == 0);
    }
    assert(mp && set_option_string(mp, "vo", "webos-ndl") == 0);
    assert(set_option_string(mp, "vd", "webos-ndl") == 0);
    assert(set_option_string(mp, "ao", "null") == 0);
    assert(set_option_string(mp, "framedrop", "no") == 0);
    assert(initialize(mp) == 0);
    request_log_messages(mp, "info");
    const char *cmd[] = {"loadfile", argv[2], NULL};
    assert(command(mp, cmd) == 0);
    int ended = 0, clock_errors = 0;
    for (int i = 0; i < 1000; ++i) {
        mpv_event *ev = wait_event(mp, 0.02);
        if (ev->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *log = ev->data;
            fprintf(stderr, "%s: %s", log->prefix, log->text);
            if (strstr(log->text, "Invalid video timestamp:")) clock_errors++;
        }
        if (ev->event_id == MPV_EVENT_END_FILE) {
            ended = ((mpv_event_end_file *)ev->data)->reason == MPV_END_FILE_REASON_EOF;
            break;
        }
    }
    int passed = ended && status() == 1 && clock_errors == 0;
    if (argc == 4) passed = passed && atomic_load(&visible) && atomic_load(&cleared);
    terminate_destroy(mp);
    overlay(NULL, NULL);
    release();
    assert(acquire("test-window"));
    release();
    return passed ? 0 : 1;
}
#endif
