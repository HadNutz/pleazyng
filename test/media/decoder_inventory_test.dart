import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/codec_catalog.dart';
import 'package:plezy/media/decoder_inventory.dart';
import 'package:plezy/media/runtime_playback_capabilities.dart';
import 'package:plezy/services/video_decode_capabilities.dart';
import 'package:plezy/sources/source_models.dart';

void main() {
  tearDown(() {
    RuntimePlaybackCapabilities.reset();
    VideoDecodeCapabilities.debugReset();
  });

  test('enumeration handles Android JSON and native node values identically', () {
    final rows = [
      {'codec': 'h264', 'driver': 'h264'},
      {'codec': 'av1', 'driver': 'av1'},
      {'codec': 'av1', 'driver': 'libdav1d'},
      {'codec': 'vc1', 'driver': 'vc1'},
      {'codec': 'vvc', 'driver': 'vvc'},
    ];
    final inventory = DecoderInventory.fromMpv(rows)!;
    expect(DecoderInventory.fromMpv(jsonEncode(rows))!.toJson(), inventory.toJson());
    expect(inventory.hasSoftwareDecoder('av01.0.08M.10'), isTrue);
    expect(inventory.contains('h266'), isTrue);
    expect(inventory.contains('av2'), isFalse);
    expect(inventory.toJson()['executionQualified'], isFalse);
  });

  test('compiled hardware wrappers do not establish software decoding', () {
    final inventory = DecoderInventory.fromMpv([
      {'codec': 'av1', 'driver': 'av1'},
      {'codec': 'hevc', 'driver': 'hevc_mediacodec'},
      {'codec': 'h264', 'driver': 'h264_cuvid'},
    ])!;
    expect(inventory.hasSoftwareDecoder('av1'), isFalse);
    expect(inventory.hasSoftwareDecoder('hevc'), isFalse);
    expect(inventory.hasSoftwareDecoder('h264'), isFalse);
  });

  test('invalid and incomplete payloads cannot replace a measured inventory', () {
    RuntimePlaybackCapabilities.recordMpvDecoders([
      {'codec': 'h264', 'driver': 'h264'},
    ]);
    for (final value in [
      null,
      '',
      'not json',
      '[]',
      {},
      [
        {'codec': 'av1'},
      ],
      [
        {'codec': '../av1', 'driver': 'av1'},
      ],
    ]) {
      RuntimePlaybackCapabilities.recordMpvDecoders(value);
      expect(RuntimePlaybackCapabilities.mpv!.decoders.keys, ['h264']);
    }
  });

  test('long-tail source decoders are advertised without becoming encode targets', () {
    RuntimePlaybackCapabilities.recordMpvDecoders([
      for (final codec in ['h264', 'hevc', 'vc1', 'mpeg1video', 'prores', 'vvc', 'rv40'])
        {'codec': codec, 'driver': codec},
    ]);
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, containsAll(['vc1', 'mpeg1video', 'prores', 'vvc', 'rv40']));
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, isNot(contains('av2')));
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, isNot(contains('vp9')));
    expect(VideoDecodeCapabilities.transcodeVideoCodecs.map((codec) => codec.id), isNot(contains('vvc')));
  });

  test('the complete descriptor catalogue includes obscure measured decoders', () {
    RuntimePlaybackCapabilities.recordMpvDecoders([
      {'codec': 'interplayvideo', 'driver': 'interplayvideo'},
      {'codec': 'escape130', 'driver': 'escape130'},
    ]);
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, containsAll(['interplayvideo', 'escape130']));
    expect(CodecCatalog.isAudioCodec('metasound'), isTrue);
    RuntimePlaybackCapabilities.activeVideoEngine = 'exoplayer';
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, isNot(contains('escape130')));
    expect(VideoDecodeCapabilities.sourceDecoderUnavailable('h264'), isFalse);
  });

  test('an unmeasured engine only advertises its compatibility baseline', () {
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, ['h264']);
    RuntimePlaybackCapabilities.activeVideoEngine = 'exoplayer';
    RuntimePlaybackCapabilities.recordMpvDecoders([
      {'codec': 'vp9', 'driver': 'vp9'},
    ]);
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, ['h264']);
    RuntimePlaybackCapabilities.activeVideoEngine = 'tizen';
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, ['h264']);
    RuntimePlaybackCapabilities.activeVideoEngine = 'webos';
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, containsAll(['h264', 'hevc', 'mpeg2video']));
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, isNot(contains('av1')));
  });

  test('hardware wrappers alone are insufficient for direct play', () {
    RuntimePlaybackCapabilities.recordMpvDecoders([
      {'codec': 'h264', 'driver': 'h264'},
      {'codec': 'vp9', 'driver': 'vp9_qsv'},
    ]);
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, ['h264']);
  });

  test('container aliases follow the actual demuxer inventory', () {
    RuntimePlaybackCapabilities.recordMpvDemuxers(['mov,mp4,m4a,3gp,3g2,mj2', 'avi', 'mpeg', 'mpegts', 'asf', 'ogg']);
    expect(
      RuntimePlaybackCapabilities.mpvVideoContainers,
      containsAll(['mp4', 'mov', 'avi', 'vob', 'qt', 'mj2', 'm2t', 'tod', 'dvr-ms', 'ogm']),
    );
    expect(RuntimePlaybackCapabilities.mpvVideoContainers, isNot(contains('mkv')));
    RuntimePlaybackCapabilities.recordMpvDemuxers(['not a demuxer']);
    expect(RuntimePlaybackCapabilities.mpvVideoContainers, isNot(contains('mkv')));
  });

  test('new and legacy media reach source browsing without claiming decode support', () {
    for (final extension in ['.vvc', '.ivf', '.apv', '.nut', '.bik', '.dvr-ms', '.m2t']) {
      expect(classifySourceFile('sample$extension'), SourceItemKind.video);
    }
    for (final extension in ['.tak', '.tta', '.shn', '.dts', '.truehd', '.aifc']) {
      expect(classifySourceFile('sample$extension'), SourceItemKind.music);
    }
    expect(classifySourceFile('book.m4b'), SourceItemKind.audiobook);
    expect(classifySourceFile('document.pdf'), SourceItemKind.ebook);
    expect(classifySourceFile('firmware.bin'), SourceItemKind.unknown);
    expect(classifySourceFile('archive.dat'), SourceItemKind.unknown);
  });

  test('codec aliases preserve profile-independent identity', () {
    expect(CodecCatalog.normalize('hvc1.2.4.L153.B0'), 'hevc');
    expect(CodecCatalog.normalize('video/x-vnd.on2.vp9'), 'vp9');
    expect(RankedVideoCodec.fromServerCodec('hvc1'), RankedVideoCodec.hevc);
    expect(RankedVideoCodec.fromServerCodec('av01.0.08M.10'), RankedVideoCodec.av1);
  });
}
