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

  test('AV2 direct play follows the loaded decoder across engine changes', () async {
    RuntimePlaybackCapabilities.recordMpvDecoders([
      {'codec': 'av2', 'driver': 'libdav2d'},
    ]);
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, contains('av2'));
    RuntimePlaybackCapabilities.recordMpvDemuxers(['mov,mp4', 'ivf', 'matroska']);
    expect(await VideoDecodeCapabilities.sourceFormatUnavailable('av2e.00M', null, container: 'mp4'), isTrue);
    expect(await VideoDecodeCapabilities.sourceFormatUnavailable('AV02', null, container: 'IVF'), isFalse);
    expect(await VideoDecodeCapabilities.sourceFormatUnavailable('av2', null, container: 'obu'), isTrue);
    RuntimePlaybackCapabilities.recordMpvDemuxers(['ivf', 'av2']);
    expect(await VideoDecodeCapabilities.sourceFormatUnavailable('av2', null, container: 'obu'), isFalse);
    expect(VideoDecodeCapabilities.transcodeVideoCodecs.map((codec) => codec.id), isNot(contains('av2')));
    await RuntimePlaybackCapabilities.withVideoEngine('tizen', () async {
      expect(VideoDecodeCapabilities.directPlayVideoCodecs, isNot(contains('av2')));
    });
    RuntimePlaybackCapabilities.recordMpvDecoders([
      {'codec': 'h264', 'driver': 'h264'},
    ]);
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, isNot(contains('av2')));
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
    expect(
      VideoDecodeCapabilities.directPlayVideoCodecs,
      unorderedEquals(['h264', 'hevc', 'av1', 'mpeg2video', 'vp8', 'vp9']),
    );
    RuntimePlaybackCapabilities.activeVideoEngine = 'webos';
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, containsAll(['h264', 'hevc', 'mpeg2video']));
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, isNot(contains('av1')));
  });

  test('each negotiation keeps its engine across asynchronous work', () async {
    RuntimePlaybackCapabilities.recordMpvDecoders([
      {'codec': 'h264', 'driver': 'h264'},
      {'codec': 'vvc', 'driver': 'vvc'},
    ]);
    final native = RuntimePlaybackCapabilities.withVideoEngine('exoplayer', () async {
      await Future<void>.value();
      return VideoDecodeCapabilities.directPlayVideoCodecs;
    });
    final desktop = RuntimePlaybackCapabilities.withVideoEngine('mpv', () async {
      await Future<void>.value();
      return VideoDecodeCapabilities.directPlayVideoCodecs;
    });
    expect(await native, ['h264']);
    expect(await desktop, ['h264', 'vvc']);
    expect(RuntimePlaybackCapabilities.activeVideoEngine, 'mpv');
  });

  test('mpv startup waits for decoders and demuxers together', () async {
    var observed = false;
    final pending = RuntimePlaybackCapabilities.waitForMpvInventory().then((_) => observed = true);
    RuntimePlaybackCapabilities.recordMpvDecoders([
      {'codec': 'h264', 'driver': 'h264'},
    ]);
    await Future<void>.value();
    expect(observed, isFalse);
    RuntimePlaybackCapabilities.recordMpvDemuxers(['mov,mp4']);
    expect(await pending, isTrue);
  });

  test('hardware wrappers alone are insufficient for direct play', () {
    RuntimePlaybackCapabilities.recordMpvDecoders([
      {'codec': 'h264', 'driver': 'h264'},
      {'codec': 'vp9', 'driver': 'vp9_qsv'},
    ]);
    expect(VideoDecodeCapabilities.directPlayVideoCodecs, ['h264']);
  });

  test('AC-4 and MPEG-H only need audio conversion when the selected engine lacks a decoder', () {
    expect(RuntimePlaybackCapabilities.sourceAudioDecoderUnavailable('ac-4'), isFalse);
    RuntimePlaybackCapabilities.recordMpvDecoders([
      {'codec': 'aac', 'driver': 'aac'},
    ]);
    expect(RuntimePlaybackCapabilities.sourceAudioDecoderUnavailable('ac-4'), isTrue);
    for (final codec in ['audio/ac-4.02.01.01', 'mha1.0x0D', 'mha2', 'mhm1', 'MHM2.0x0D']) {
      expect(RuntimePlaybackCapabilities.sourceAudioDecoderUnavailable(codec), isTrue, reason: codec);
    }
    expect(RuntimePlaybackCapabilities.sourceAudioDecoderUnavailable('truehd'), isFalse);
    RuntimePlaybackCapabilities.recordMpvDecoders([
      {'codec': 'ac4', 'driver': 'ac4'},
    ]);
    expect(RuntimePlaybackCapabilities.sourceAudioDecoderUnavailable('ac4'), isFalse);
    expect(
      RuntimePlaybackCapabilities.withVideoEngine(
        'webos',
        () => RuntimePlaybackCapabilities.sourceAudioDecoderUnavailable('mpegh'),
      ),
      isFalse,
    );
  });

  test('disc capability comes from the loaded mpv protocol inventory', () {
    expect(RuntimePlaybackCapabilities.mpvSupportsProtocol('dvd'), isNull);
    RuntimePlaybackCapabilities.recordMpvProtocols('["file","http","bd"]');
    expect(RuntimePlaybackCapabilities.mpvSupportsProtocol('bd'), isTrue);
    expect(RuntimePlaybackCapabilities.mpvSupportsProtocol('dvd'), isFalse);
    RuntimePlaybackCapabilities.recordMpvProtocols(['file', 1]);
    expect(RuntimePlaybackCapabilities.mpvSupportsProtocol('bd'), isTrue);
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

  test('elementary stream preflight uses the codec-specific native reader', () async {
    RuntimePlaybackCapabilities.recordMpvDecoders([
      for (final codec in ['h264', 'hevc', 'av1', 'jpegxl', 'jpegxl_anim']) {'codec': codec, 'driver': codec},
    ]);
    RuntimePlaybackCapabilities.recordMpvDemuxers(['h264', 'obu', 'jpegxl_pipe', 'matroska']);
    expect(await VideoDecodeCapabilities.sourceFormatUnavailable('avc1', null, container: '264'), isFalse);
    expect(await VideoDecodeCapabilities.sourceFormatUnavailable('h265', null, container: '265'), isTrue);
    expect(await VideoDecodeCapabilities.sourceFormatUnavailable('h265', null, container: 'mkv'), isFalse);
    expect(await VideoDecodeCapabilities.sourceFormatUnavailable('av1', null, container: 'obu'), isFalse);
    expect(await VideoDecodeCapabilities.sourceFormatUnavailable('jpegxl', null, container: 'jxl'), isFalse);
    expect(await VideoDecodeCapabilities.sourceFormatUnavailable('jpegxl_anim', null, container: 'jxl'), isTrue);
  });

  test('new and legacy media reach source browsing without claiming decode support', () {
    for (final extension in [
      '.vvc',
      '.ivf',
      '.obu',
      '.apv',
      '.jxl',
      '.nut',
      '.bik',
      '.dvr-ms',
      '.m2t',
      '.mpegts',
      '.avc',
      '.h26l',
    ]) {
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
    expect(CodecCatalog.normalize('AV02'), 'av2');
    expect(CodecCatalog.normalize('av2e.00M'), 'av2');
    expect(CodecCatalog.normalize('av2E.4AH'), 'av2');
    expect(CodecCatalog.normalize('av2E.4AW'), 'av2e.4aw');
    expect(CodecCatalog.normalize('mp4a.40.42'), 'mp4a.40.42');
    expect(RankedVideoCodec.fromServerCodec('hvc1'), RankedVideoCodec.hevc);
    expect(RankedVideoCodec.fromServerCodec('av01.0.08M.10'), RankedVideoCodec.av1);
  });
}
