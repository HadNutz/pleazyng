/// An authenticated remote exchanges opaque library identifiers and playback
/// time. The handset always resolves media and credentials independently.
typedef ListeningFile = ({String server, String item, String source, int? part});

class ListeningClock {
  const ListeningClock(this.file, this.position, this.playing, this.rate);
  final ListeningFile file;
  final Duration position;
  final bool playing;
  final double rate;

  Map<String, dynamic> toJson() => {
    'server': file.server,
    'item': file.item,
    'source': file.source,
    'part': file.part,
    'ms': position.inMilliseconds,
    'playing': playing,
    'rate': rate,
  };

  static ListeningClock? parse(Map<String, dynamic>? data) {
    if (data == null) return null;
    final server = data['server'], item = data['item'], source = data['source'], part = data['part'];
    final ms = data['ms'], playing = data['playing'], rate = data['rate'];
    final id = RegExp(r'^[a-zA-Z0-9_-]{1,160}$');
    if (server is! String ||
        !id.hasMatch(server) ||
        item is! String ||
        !id.hasMatch(item) ||
        source is! String ||
        !id.hasMatch(source) ||
        (part != null && (part is! int || part < 0)) ||
        ms is! int ||
        ms < 0 ||
        ms > const Duration(days: 30).inMilliseconds ||
        playing is! bool ||
        rate is! num ||
        !rate.isFinite ||
        rate <= 0 ||
        rate > 16) {
      return null;
    }
    return ListeningClock(
      (server: server, item: item, source: source, part: part as int?),
      Duration(milliseconds: ms),
      playing,
      rate.toDouble(),
    );
  }

  Duration target(Duration sinceSample, Duration advance) {
    final delta = playing ? (sinceSample.inMicroseconds * rate).round() + advance.inMicroseconds : 0;
    final micros = position.inMicroseconds + delta;
    return Duration(microseconds: micros < 0 ? 0 : micros);
  }
}

({bool seek, double speed}) listeningCorrection(
  Duration drift, {
  required bool playing,
  required double rate,
  bool resync = false,
}) {
  final ms = drift.inMilliseconds;
  final seek = resync || ms.abs() > (playing ? 350 : 60);
  final correction = !playing || seek || ms.abs() < 45 ? 0.0 : (ms / 2000).clamp(-.04, .04);
  return (seek: seek, speed: rate * (1 + correction));
}
