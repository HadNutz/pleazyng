
DISABLED_PATCHES="strip_swscale strip_mpv_dead strip_libass libsmb2"
AUDIO_DECODERS+=",libdav1d,h264,hevc,mpeg2video,mpeg4,vp8,vp9,av1,theora,mjpeg,wmv3,vc1,h263,flv"
AUDIO_PARSERS+=",h264,hevc,mpegvideo,mpeg4video,vp8,vp9,av1,vc1"
AUDIO_FILTERS+=",scale,format"
AUDIO_DECODERS+=",h264_v4l2m2m,hevc_v4l2m2m,mpeg2_v4l2m2m,mpeg4_v4l2m2m,h263_v4l2m2m,vc1_v4l2m2m,vp8_v4l2m2m,vp9_v4l2m2m"
AUDIO_BSFS+=",h264_mp4toannexb,hevc_mp4toannexb"
AUDIO_DECODERS+=",ass,ssa,subrip,srt,webvtt,movtext,text,dvdsub,dvbsub,pgssub,xsub,microdvd,sami,subviewer,subviewer1,jacosub,mpl2,pjs,realtext,vplayer,ccaption"
AUDIO_PARSERS+=",dvbsub,dvdsub"
