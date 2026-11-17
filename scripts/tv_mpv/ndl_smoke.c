// SPDX-License-Identifier: LGPL-2.1-or-later
// Build twice with the LG NDK: as a test NDL .so (-DMOCK_NDL), and as a
// client. The client exercises the real mpv decoder and video-output modules.
// The mock captures what the board decoder would receive for offline decoding.
#ifdef MOCK_NDL
#include <NDL/NDL_directmedia.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static FILE *out;
bool NDL_DirectMedia_DL_Initialize(void) { return true; }
int NDL_DirectMediaSetWindowId(const char *id) { return strcmp(id, "test-window"); }
int NDL_DirectMediaInit(const char *app) { return strcmp(app, "org.snapetech.pleazyng"); }
int NDL_DirectMediaSetAppState(NDL_DIRECTMEDIA_APP_STATE s) { return 0; }
int NDL_DirectMediaLoad(NDL_DIRECTMEDIA_DATA_INFO_T *m, StateCallbackFP cb) {
    if (m->videoDataInfo.source != NDL_DIRECTVIDEO_SRC_TYPE_H264 &&
        m->videoDataInfo.source != NDL_DIRECTVIDEO_SRC_TYPE_HEVC) return -1;
    out = fopen(getenv("NDL_CAPTURE"), "wb");
    return out ? 0 : -1;
}
int NDL_DirectMediaUnload(void) { if (out) fclose(out); out = NULL; return 0; }
int NDL_DirectMediaQuit(void) { return 0; }
int NDL_DirectVideoSetArea(int x, int y, int w, int h) {
    return w == atoi(getenv("NDL_WIDTH")) && h == atoi(getenv("NDL_HEIGHT")) ? 0 : -1;
}
int NDL_DirectVideoPlay(void *data, unsigned size, long long pts) {
    const unsigned char *p = data;
    if (size < 4 || p[0] || p[1] || (p[2] != 1 && (p[2] || p[3] != 1))) return -1;
    return fwrite(data, 1, size, out) == size ? 0 : -1;
}
int NDL_DirectVideoFlushRenderBuffer(void) { return 0; }
#else
#include "../../shared/tv_mpv/include/mpv/client.h"
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    assert(argc == 3);
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
    mpv_handle *mp = create();
    assert(mp && set_option_string(mp, "vo", "webos-ndl") == 0);
    assert(set_option_string(mp, "vd", "webos-ndl") == 0);
    assert(set_option_string(mp, "ao", "null") == 0);
    assert(set_option_string(mp, "framedrop", "no") == 0);
    assert(initialize(mp) == 0);
    request_log_messages(mp, "info");
    const char *cmd[] = {"loadfile", argv[2], NULL};
    assert(command(mp, cmd) == 0);
    int ended = 0;
    for (int i = 0; i < 1000; ++i) {
        mpv_event *ev = wait_event(mp, 0.02);
        if (ev->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *log = ev->data;
            fprintf(stderr, "%s: %s", log->prefix, log->text);
        }
        if (ev->event_id == MPV_EVENT_END_FILE) {
            ended = ((mpv_event_end_file *)ev->data)->reason == MPV_END_FILE_REASON_EOF;
            break;
        }
    }
    int passed = ended && status() == 1;
    terminate_destroy(mp);
    release();
    assert(acquire("test-window"));
    release();
    return passed ? 0 : 1;
}
#endif
