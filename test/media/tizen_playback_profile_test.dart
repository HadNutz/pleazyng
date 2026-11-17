import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/tizen_playback_profile.dart';

void main() {
  test('Samsung profile advertises native UHD sources and a compatible HLS conversion', () {
    final profile = tizenPlaybackProfile(audio: false, burnSubtitles: false);
    final transcode = (profile['TranscodingProfiles'] as List).single as Map;
    expect(transcode['Protocol'], 'hls');
    expect(transcode['VideoCodec'], 'h264');
    expect(transcode['MaxAudioChannels'], '2');
    expect(profile['SubtitleProfiles'], [
      {'Format': 'srt', 'Method': 'External'},
      {'Format': 'vtt', 'Method': 'External'},
    ]);
    expect(profile.toString(), contains('hevc'));
    expect(profile.toString(), contains('vp9'));
    expect(profile.toString(), isNot(contains('1080')));
  });
  test('burn-in does not simultaneously advertise external subtitle delivery', () {
    expect(tizenPlaybackProfile(audio: true, burnSubtitles: true)['SubtitleProfiles'], isEmpty);
  });
  test('a refused codec stays out of Samsung original-source profiles', () {
    final profile = tizenPlaybackProfile(audio: false, burnSubtitles: false, refusedVideo: {'av1'});
    expect(profile['DirectPlayProfiles'].toString(), isNot(contains('av1')));
    expect(profile['DirectPlayProfiles'].toString(), contains('hevc'));
  });
}
