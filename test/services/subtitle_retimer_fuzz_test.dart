import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/subtitle_retimer.dart';

void main() {
  test('bounded deterministic mutations never escape the subtitle parser contract', () {
    final seeds = <(String extension, List<int> bytes)>[
      (
        '.srt',
        utf8.encode(
          '''1\n00:00:01,000 --> 00:00:02,250\nHello world.\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond line.\n''',
        ),
      ),
      (
        '.vtt',
        utf8.encode(
          '''WEBVTT\n\nintro\n00:00:01.000 --> 00:00:02.250 align:start\nHello world.\n\n00:00:03.000 --> 00:00:04.000\nSecond line.\n''',
        ),
      ),
      (
        '.ass',
        utf8.encode(
          '''[Script Info]\nTitle: Fuzz seed\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize\nStyle: Default,Arial,20\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.25,Default,,0,0,0,,Hello world.\n''',
        ),
      ),
      (
        '.ssa',
        utf8.encode(
          '''[Script Info]\nTitle: Fuzz seed\n[V4 Styles]\nFormat: Name, Fontname, Fontsize\nStyle: Default,Arial,20\n[Events]\nFormat: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: Marked=0,0:00:01.00,0:00:02.25,Default,,0,0,0,,Hello world.\n''',
        ),
      ),
    ];
    final random = _DeterministicRandom(0x504c5a59);
    var inputCount = 0;

    for (final (extension, seed) in seeds) {
      for (var iteration = 0; iteration < 128; iteration++) {
        final input = _mutate(seed, random, iteration);
        _expectParserContract(extension, input);
        inputCount++;
      }
    }

    for (var iteration = 0; iteration < 128; iteration++) {
      final extension = seeds[iteration % seeds.length].$1;
      final length = 1 + random.nextInt(512);
      final input = List<int>.generate(length, (_) => random.nextInt(256), growable: false);
      _expectParserContract(extension, input);
      inputCount++;
    }

    expect(inputCount, 640);
  });
}

void _expectParserContract(String extension, List<int> input) {
  final original = List<int>.of(input);
  List<SubtitleCue>? cues;
  try {
    cues = SubtitleRetimer.parseCues(sourceBytes: input, extension: extension);
  } on FormatException {
    // Malformed input is an expected parser outcome. Other exception types
    // escape the test and expose an unexpected parser failure.
  }

  expect(input, original, reason: 'The $extension parser must not mutate input bytes.');
  if (cues == null) return;
  expect(cues.length, lessThanOrEqualTo(SubtitleRetimer.maximumCueCount));
  expect(cues.map((cue) => cue.id).toSet(), hasLength(cues.length));
  for (final cue in cues) {
    expect(SubtitleCue.isValidId(cue.id), isTrue);
    expect(cue.startMs, greaterThanOrEqualTo(0));
    expect(cue.endMs, greaterThan(cue.startMs));
    expect(cue.endMs, lessThanOrEqualTo(SubtitleRetimer.maximumTimeMs));
  }
}

List<int> _mutate(List<int> seed, _DeterministicRandom random, int iteration) {
  final bytes = List<int>.of(seed);
  switch (iteration % 5) {
    case 0:
      if (bytes.isNotEmpty) {
        final index = random.nextInt(bytes.length);
        bytes[index] ^= 1 << random.nextInt(8);
      }
    case 1:
      final index = random.nextInt(bytes.length + 1);
      bytes.insert(index, random.nextInt(256));
    case 2:
      if (bytes.isNotEmpty) bytes.removeAt(random.nextInt(bytes.length));
    case 3:
      final prefixLength = random.nextInt(bytes.length + 1);
      bytes.removeRange(prefixLength, bytes.length);
    case 4:
      final suffixLength = random.nextInt(17);
      bytes.addAll(List<int>.generate(suffixLength, (_) => random.nextInt(256)));
  }
  if (bytes.isEmpty) bytes.add(0);
  return bytes;
}

/// Park–Miller keeps corpus generation reproducible without relying on
/// `Random`'s implementation details; its integer multiplication stays below
/// the exact-integer limit used by Dart's native and web runtimes.
final class _DeterministicRandom {
  _DeterministicRandom(int seed) : _state = seed & 0x7fffffff;

  int _state;

  int nextInt(int maximum) {
    _state = (48271 * _state) % 2147483647;
    return _state % maximum;
  }
}
