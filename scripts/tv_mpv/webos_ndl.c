// SPDX-License-Identifier: LGPL-2.1-or-later
// Built into the pinned webOS libmpv. mpv owns demux, clocks, audio and seek.
// Opaque video frames carry compressed access units to the NDL video plane.
#include <NDL/NDL_directmedia.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <pthread.h>
#include <math.h>
#include <libavcodec/bsf.h>
#include <libplacebo/utils/libav.h>
#include <libavutil/mastering_display_metadata.h>
#include "common/av_common.h"
#include "common/codecs.h"
#include "common/msg.h"
#include "demux/packet.h"
#include "demux/stheader.h"
#include "filters/f_decoder_wrapper.h"
#include "filters/filter_internal.h"
#include "osdep/timer.h"
#include "video/mp_image.h"
#include "video/out/vo.h"

#define PUBLIC __attribute__((visibility("default")))
#define NDL_FN(name) __typeof__(&NDL_##name) name
static struct {
    void *lib;
    bool (*initialize)(void);
    NDL_FN(DirectMediaSetWindowId);
    NDL_FN(DirectMediaInit);
    NDL_FN(DirectMediaSetAppState);
    NDL_FN(DirectMediaLoad);
    NDL_FN(DirectMediaUnload);
    NDL_FN(DirectMediaQuit);
    NDL_FN(DirectVideoPlay);
    NDL_FN(DirectVideoFlushRenderBuffer);
    NDL_FN(DirectVideoSetArea);
    NDL_FN(DirectVideoSetHDRInfo);
} api;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static bool owned;
static atomic_int status;
static void event_callback(int type, long long value, const char *text) {}

PUBLIC int mpv_pleazyng_ndl_acquire(const char *window)
{
    const char *app = getenv("APPID");
    if (!app || !*app) app = "org.snapetech.pleazyng";
    if (!window || !*window)
        return 0;
    pthread_mutex_lock(&lock);
    if (owned) goto fail;
    if (!api.lib) {
        api.lib = dlopen("libNDL_directmedia.so.1", RTLD_NOW | RTLD_LOCAL);
        if (!api.lib) goto fail;
        api.initialize = dlsym(api.lib, "NDL_DirectMedia_DL_Initialize");
#define LOOKUP(name) if (!(api.name = dlsym(api.lib, "NDL_" #name))) goto missing
        LOOKUP(DirectMediaSetWindowId);
        LOOKUP(DirectMediaInit);
        LOOKUP(DirectMediaSetAppState);
        LOOKUP(DirectMediaLoad);
        LOOKUP(DirectMediaUnload);
        LOOKUP(DirectMediaQuit);
        LOOKUP(DirectVideoPlay);
        LOOKUP(DirectVideoFlushRenderBuffer);
        LOOKUP(DirectVideoSetArea);
        api.DirectVideoSetHDRInfo = dlsym(api.lib, "NDL_DirectVideoSetHDRInfo");
        if (!api.initialize || !api.initialize()) goto missing;
    }
    if (api.DirectMediaSetWindowId(window) || api.DirectMediaInit(app)) goto fail;
    if (api.DirectMediaSetAppState(NDL_DIRECTMEDIA_APP_STATE_FOREGROUND)) {
        api.DirectMediaQuit();
        goto fail;
    }
    atomic_store(&status, 0);
    owned = true;
    pthread_mutex_unlock(&lock);
    return 1;
missing:
    dlclose(api.lib);
    api.lib = NULL;
fail:
    pthread_mutex_unlock(&lock);
    return 0;
}

PUBLIC void mpv_pleazyng_ndl_release(void)
{
    pthread_mutex_lock(&lock);
    if (owned) api.DirectMediaQuit();
    owned = false;
    pthread_mutex_unlock(&lock);
}

PUBLIC int mpv_pleazyng_ndl_status(void) { return atomic_load(&status); }

struct decoder {
    struct mp_decoder public;
    struct mp_codec_params *codec;
    AVBSFContext *bsf;
    int source;
    NDL_DIRECTVIDEO_HDR_INFO_T hdr;
    bool hdr_enabled;
};

static const struct {const char *name; int source; const char *filter;} formats[] = {
    {"h264", NDL_DIRECTVIDEO_SRC_TYPE_H264, "h264_mp4toannexb"},
    {"hevc", NDL_DIRECTVIDEO_SRC_TYPE_HEVC, "hevc_mp4toannexb"},
    {"vp9", NDL_DIRECTVIDEO_SRC_TYPE_VP9, "null"},
    {"av1", NDL_DIRECTVIDEO_SRC_TYPE_AV1, "null"},
};

// VP9 carries mastering data in the container. NDL needs that metadata
// separately from the elementary stream. Coordinates and luminance follow
// the integer units used in mastering-display-colour-volume SEI.
static void update_metadata(NDL_DIRECTVIDEO_HDR_INFO_T *hdr, const AVPacketSideData *side, int count)
{
    const AVPacketSideData *master = av_packet_side_data_get(side, count, AV_PKT_DATA_MASTERING_DISPLAY_METADATA);
    if (master && master->size >= sizeof(AVMasteringDisplayMetadata)) {
        const AVMasteringDisplayMetadata *m = (const void *)master->data;
        if (m->has_primaries) {
            hdr->displayPrimariesRx = lrint(50000 * av_q2d(m->display_primaries[0][0]));
            hdr->displayPrimariesRy = lrint(50000 * av_q2d(m->display_primaries[0][1]));
            hdr->displayPrimariesGx = lrint(50000 * av_q2d(m->display_primaries[1][0]));
            hdr->displayPrimariesGy = lrint(50000 * av_q2d(m->display_primaries[1][1]));
            hdr->displayPrimariesBx = lrint(50000 * av_q2d(m->display_primaries[2][0]));
            hdr->displayPrimariesBy = lrint(50000 * av_q2d(m->display_primaries[2][1]));
            hdr->whitePointX = lrint(50000 * av_q2d(m->white_point[0]));
            hdr->whitePointY = lrint(50000 * av_q2d(m->white_point[1]));
        }
        if (m->has_luminance) {
            hdr->minDisplayMasteringLuminance = lrint(10000 * av_q2d(m->min_luminance));
            hdr->maxDisplayMasteringLuminance = lrint(10000 * av_q2d(m->max_luminance));
        }
    }
    const AVPacketSideData *light = av_packet_side_data_get(side, count, AV_PKT_DATA_CONTENT_LIGHT_LEVEL);
    if (light && light->size >= sizeof(AVContentLightMetadata)) {
        const AVContentLightMetadata *m = (const void *)light->data;
        hdr->maxContentLightLevel = m->MaxCLL;
        hdr->maxFrameAverageLightLevel = m->MaxFALL;
    }
}
static void free_packet(void *p) { AVPacket *pkt = p; av_packet_free(&pkt); }

static void process(struct mp_filter *f)
{
    struct decoder *d = f->priv;
    if (!mp_pin_can_transfer_data(f->ppins[1], f->ppins[0])) return;
    struct mp_frame in = mp_pin_out_read(f->ppins[0]);
    if (in.type == MP_FRAME_EOF) {
        mp_pin_in_write(f->ppins[1], in);
        return;
    }
    if (in.type != MP_FRAME_PACKET) { mp_frame_unref(&in); return; }
    struct demux_packet *src = in.data;
    AVRational tb = AV_TIME_BASE_Q;
    AVPacket borrowed = {0};
    mp_set_av_packet(&borrowed, src, &tb);
    AVPacket *pkt = av_packet_clone(&borrowed);
    struct mp_image img = {0};
    mp_image_setfmt(&img, IMGFMT_WEBOS_NDL);
    mp_image_set_size(&img, d->codec->disp_w, d->codec->disp_h);
    // Feed the device in decode order. The hardware receives the original PTS
    // separately and reorders B pictures. mpv paces access units on its clock.
    img.dts = img.pts = src->dts == MP_NOPTS_VALUE ? src->pts : src->dts;
    img.pkt_duration = src->duration;
    img.params.p_w = MPMAX(1, d->codec->par_w);
    img.params.p_h = MPMAX(1, d->codec->par_h);
    mp_frame_unref(&in);
    if (!pkt || av_bsf_send_packet(d->bsf, pkt) < 0) goto fail;
    int rc = av_bsf_receive_packet(d->bsf, pkt);
    if (rc == AVERROR(EAGAIN)) {
        av_packet_free(&pkt);
        mp_filter_internal_mark_progress(f);
        return;
    }
    if (rc < 0) goto fail;
    if (d->hdr_enabled) {
        update_metadata(&d->hdr, pkt->side_data, pkt->side_data_elems);
        av_buffer_unref(&pkt->opaque_ref);
        pkt->opaque_ref = av_buffer_alloc(sizeof(d->hdr));
        if (!pkt->opaque_ref) goto fail;
        memcpy(pkt->opaque_ref->data, &d->hdr, sizeof(d->hdr));
    } else {
        av_buffer_unref(&pkt->opaque_ref);
    }
    img.planes[0] = (uint8_t *)pkt;
    img.planes[1] = (uint8_t *)(uintptr_t)d->source;
    struct mp_image *out = mp_image_new_custom_ref(&img, pkt, free_packet);
    if (!out) return; // the reference constructor releases pkt
    mp_pin_in_write(f->ppins[1], MAKE_FRAME(MP_FRAME_VIDEO, out));
    return;
fail:
    av_packet_free(&pkt);
    atomic_store(&status, -1);
    mp_filter_internal_mark_failed(f);
}

static void reset(struct mp_filter *f)
{
    struct decoder *d = f->priv;
    if (d->bsf) av_bsf_flush(d->bsf);
}

static void destroy(struct mp_filter *f)
{
    struct decoder *d = f->priv;
    av_bsf_free(&d->bsf);
}

static const struct mp_filter_info filter = {
    .name="webos-ndl", .priv_size=sizeof(struct decoder), .process=process,
    .reset=reset, .destroy=destroy,
};

static struct mp_decoder *create(struct mp_filter *parent, struct mp_codec_params *codec,
                                 const char *name)
{
    if (!owned || !codec->codec || codec->disp_w <= 0 || codec->disp_h <= 0) return NULL;
    for (int i = 0; i < MP_ARRAY_SIZE(formats); ++i) {
        if (strcmp(codec->codec, formats[i].name)) continue;
        struct mp_filter *f = mp_filter_create(parent, &filter);
        struct decoder *d = f->priv;
        d->public.f = f;
        d->codec = codec;
        d->source = formats[i].source;
        const AVBitStreamFilter *bsf = av_bsf_get_by_name(formats[i].filter);
        AVCodecParameters *p = mp_codec_params_to_av(codec);
        bool ok = bsf && p && av_bsf_alloc(bsf, &d->bsf) >= 0 &&
                  avcodec_parameters_copy(d->bsf->par_in, p) >= 0;
        // mpv's Matroska demuxer stores Colour and MasteringMetadata in
        // mp_codec_params. libavformat-backed sources use AVCodecParameters.
        if (ok && d->source == NDL_DIRECTVIDEO_SRC_TYPE_VP9 &&
            (codec->color.transfer == PL_COLOR_TRC_PQ || codec->color.transfer == PL_COLOR_TRC_HLG)) {
            p->color_trc = pl_transfer_to_av(codec->color.transfer);
            p->color_primaries = pl_primaries_to_av(codec->color.primaries);
            p->color_space = pl_system_to_av(codec->repr.sys);
            const struct pl_hdr_metadata *h = &codec->color.hdr;
            d->hdr.displayPrimariesRx = lrintf(50000 * h->prim.red.x);
            d->hdr.displayPrimariesRy = lrintf(50000 * h->prim.red.y);
            d->hdr.displayPrimariesGx = lrintf(50000 * h->prim.green.x);
            d->hdr.displayPrimariesGy = lrintf(50000 * h->prim.green.y);
            d->hdr.displayPrimariesBx = lrintf(50000 * h->prim.blue.x);
            d->hdr.displayPrimariesBy = lrintf(50000 * h->prim.blue.y);
            d->hdr.whitePointX = lrintf(50000 * h->prim.white.x);
            d->hdr.whitePointY = lrintf(50000 * h->prim.white.y);
            d->hdr.minDisplayMasteringLuminance = lrintf(10000 * h->min_luma);
            d->hdr.maxDisplayMasteringLuminance = lrintf(10000 * h->max_luma);
            d->hdr.maxContentLightLevel = lrintf(h->max_cll);
            d->hdr.maxFrameAverageLightLevel = lrintf(h->max_fall);
        }
        if (ok && d->source == NDL_DIRECTVIDEO_SRC_TYPE_VP9 &&
            (p->color_trc == AVCOL_TRC_SMPTE2084 || p->color_trc == AVCOL_TRC_ARIB_STD_B67)) {
            d->hdr_enabled = true;
            d->hdr.transferCharacteristics = p->color_trc;
            d->hdr.colorPrimaries = p->color_primaries;
            d->hdr.matrixCoeffs = p->color_space;
            update_metadata(&d->hdr, p->coded_side_data, p->nb_coded_side_data);
            ok = api.DirectVideoSetHDRInfo != NULL;
        }
        avcodec_parameters_free(&p);
        if (ok) {
            d->bsf->time_base_in = AV_TIME_BASE_Q;
            ok = av_bsf_init(d->bsf) >= 0;
        }
        if (!ok) { talloc_free(f); break; }
        mp_filter_add_pin(f, MP_PIN_IN, "in");
        mp_filter_add_pin(f, MP_PIN_OUT, "out");
        return &d->public;
    }
    atomic_store(&status, -1);
    return NULL;
}

static void list(struct mp_decoder_list *decoders)
{
    for (int i = 0; i < MP_ARRAY_SIZE(formats); ++i)
        mp_add_decoder(decoders, formats[i].name, "webos-ndl", "LG native video plane");
}
const struct mp_decoder_fns vd_webos_ndl = {.create=create, .add_decoders=list};

struct output { int w, h, source; uint64_t last; bool loaded, have_hdr; NDL_DIRECTVIDEO_HDR_INFO_T hdr; };

static void output_close(struct vo *vo)
{
    struct output *o = vo->priv;
    if (o->loaded) api.DirectMediaUnload();
    o->loaded = o->have_hdr = false;
}

static bool draw(struct vo *vo, struct vo_frame *frame)
{
    struct output *o = vo->priv;
    struct mp_image *img = frame->current;
    if (!img || frame->frame_id == o->last || atomic_load(&status) < 0) return true;
    int source = (int)(uintptr_t)img->planes[1];
    if (!o->loaded || o->w != img->w || o->h != img->h || o->source != source) {
        output_close(vo);
        NDL_DIRECTMEDIA_DATA_INFO_T media = {0};
        media.videoDataInfo.width = img->w;
        media.videoDataInfo.height = img->h;
        media.videoDataInfo.source = source;
        if (api.DirectMediaLoad(&media, event_callback)) goto fail;
        o->loaded = true;
        o->w = img->w; o->h = img->h; o->source = source;
        if (api.DirectVideoSetArea(0,0,o->w,o->h)) goto fail;
    }
    AVPacket *pkt = (void *)img->planes[0];
    if (pkt->opaque_ref) {
        const NDL_DIRECTVIDEO_HDR_INFO_T *hdr = (const void *)pkt->opaque_ref->data;
        if (!o->have_hdr || memcmp(&o->hdr, hdr, sizeof(*hdr))) {
            if (!api.DirectVideoSetHDRInfo || api.DirectVideoSetHDRInfo(*hdr)) goto fail;
            o->hdr = *hdr;
            o->have_hdr = true;
        }
    }
    long long pts = pkt->pts != AV_NOPTS_VALUE ? pkt->pts :
                    pkt->dts != AV_NOPTS_VALUE ? pkt->dts : 0;
    for (int n = 0; n < 100; ++n) {
        if (!api.DirectVideoPlay(pkt->data, pkt->size, pts)) {
            o->last = frame->frame_id;
            atomic_store(&status, 1);
            return true;
        }
        mp_sleep_ns(5 * 1000 * 1000);
    }
fail:
    atomic_store(&status, -1);
    return false;
}

static int query(struct vo *vo, int fmt) { return fmt == IMGFMT_WEBOS_NDL; }
static int config(struct vo *vo, struct mp_image_params *p) { return 0; }
static int start(struct vo *vo) { return owned ? 0 : -1; }
static void flip(struct vo *vo) {}
static int control(struct vo *vo, uint32_t req, void *data)
{
    struct output *o = vo->priv;
    if (req == VOCTRL_RESET && o->loaded) {
        api.DirectVideoFlushRenderBuffer();
        o->last = 0;
        return VO_TRUE;
    }
    return VO_NOTIMPL;
}
const struct vo_driver video_out_webos_ndl = {
    .name="webos-ndl", .description="LG NDL native hardware video plane",
    .preinit=start, .query_format=query, .reconfig=config, .control=control,
    .draw_frame=draw, .flip_page=flip, .uninit=output_close, .priv_size=sizeof(struct output),
};
