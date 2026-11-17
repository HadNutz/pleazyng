"""Integrate the LG compressed-packet decoder/output into the pinned mpv source."""
from pathlib import Path
import shutil
import sys


def integrate(tree):
    def replace(path, old, new):
        target = tree / path
        data = target.read_text()
        if data.count(old) != 1:
            raise ValueError(f"unexpected pinned mpv source in {path}: {old}")
        target.write_text(data.replace(old, new))
    shutil.copyfile(Path(__file__).with_name("webos_ndl.c"), tree / "video/out/webos_ndl.c")
    replace("meson.build", "'video/out/vo_null.c',", "'video/out/vo_null.c',\n    'video/out/webos_ndl.c',")
    replace("video/img_format.h", "    IMGFMT_CUST_BASE,", "    IMGFMT_CUST_BASE,\n    IMGFMT_WEBOS_NDL,")
    replace("video/img_format.c", "    [IMGFMT_VDPAU_OUTPUT", """    [IMGFMT_WEBOS_NDL - IMGFMT_CUST_BASE] = {
        .name = "webos-ndl",
        .desc = {.flags = MP_IMGFLAG_NE | MP_IMGFLAG_COLOR_YUV | MP_IMGFLAG_HWACCEL},
    },
    [IMGFMT_VDPAU_OUTPUT""")
    replace("video/out/vo.c", "extern const struct vo_driver video_out_null;",
            "extern const struct vo_driver video_out_webos_ndl;\nextern const struct vo_driver video_out_null;")
    replace("video/out/vo.c", "    &video_out_null,", "    &video_out_null,\n    &video_out_webos_ndl,")
    replace("filters/f_decoder_wrapper.c", "        fallback = \"h264\";", """        fallback = "h264";
        if (user_list && !strcmp(user_list, "webos-ndl")) {
            extern const struct mp_decoder_fns vd_webos_ndl;
            driver = &vd_webos_ndl;
        }""")


if __name__ == "__main__":
    integrate(Path(sys.argv[1]))
