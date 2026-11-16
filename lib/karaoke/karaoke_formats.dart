import 'dart:math' as math;

import 'package:xml/xml.dart';

import '../media/lyrics.dart';
import '../utils/lrc_parser.dart';
import 'karaoke_models.dart';

class KaraokeTextImport {
  final Lyrics lyrics;
  final List<KaraokeNote> notes;
  final Map<String, String> metadata;
  final List<String> warnings;
  const KaraokeTextImport(this.lyrics, {this.notes = const [], this.metadata = const {}, this.warnings = const []});
}

/// Deliberately documented subset; originals are retained by the package store.
class KaraokeFormats {
  // Stay below 2^43 seconds so the parser's double-based clock conversion
  // retains millisecond precision on every supported Dart target.
  static const int _maxPreciseTimeMs = (1 << 43) * 1000 - 1;

  static KaraokeTextImport parse(String text, String extension) {
    if (text.length > 8 * 1024 * 1024) {
      throw const FormatException('Lyrics exceed 8 MiB');
    }
    return switch (extension.toLowerCase()) {
      '.lrc' => KaraokeTextImport(parseLrc(text) ?? const Lyrics(synced: false, lines: [])),
      '.vtt' => _vtt(text),
      '.ttml' || '.xml' => _ttml(text),
      '.txt' when text.contains('#BPM:') => _ultraStar(text),
      '.txt' => KaraokeTextImport(
        Lyrics(synced: false, lines: text.split('\n').map((s) => LyricLine(text: s)).toList()),
      ),
      _ => throw UnsupportedError('Unsupported lyric format: $extension'),
    };
  }

  static int _time(String value) {
    final v = value.trim();
    final offset = RegExp(r'^(\d+(?:\.\d+)?)(ms|s|m|h)$').firstMatch(v);
    if (offset != null) {
      return (double.parse(offset[1]!) *
              switch (offset[2]) {
                'ms' => 1,
                's' => 1000,
                'm' => 60000,
                _ => 3600000,
              })
          .round();
    }
    if (!RegExp(r'^(\d+:)?\d{2}:\d{2}(\.\d{1,3})?$').hasMatch(v)) {
      throw FormatException('Unsupported time expression: $v');
    }
    var seconds = 0.0;
    for (final part in v.split(':')) {
      seconds = seconds * 60 + double.parse(part);
    }
    return (seconds * 1000).round();
  }

  static String _entities(String text) => text
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', '\u00a0')
      .replaceAll('&lrm;', '\u200e')
      .replaceAll('&rlm;', '\u200f')
      .replaceAll('&amp;', '&');

  static KaraokeTextImport _vtt(String text) {
    if (!text.replaceFirst('\ufeff', '').startsWith('WEBVTT')) {
      throw const FormatException('Missing WEBVTT header');
    }
    final lines = <LyricLine>[];
    final warnings = <String>{};
    for (final block in text.replaceAll('\r', '').split(RegExp(r'\n\s*\n'))) {
      final rows = block.split('\n');
      if (rows.first.startsWith('NOTE')) {
        continue;
      }
      if (rows.first == 'STYLE' || rows.first == 'REGION') {
        warnings.add('WebVTT styles/regions are preserved in the original only');
        continue;
      }
      final i = rows.indexWhere((r) => r.contains('-->'));
      if (i < 0) {
        continue;
      }
      final timing = RegExp(r'^(\S+)\s+-->\s+(\S+)(.*)$').firstMatch(rows[i]);
      if (timing == null) {
        throw const FormatException('Invalid WebVTT timing');
      }
      final start = _time(timing[1]!), end = _time(timing[2]!);
      if (end <= start) {
        throw const FormatException('WebVTT end precedes start');
      }
      if (timing[3]!.trim().isNotEmpty) {
        warnings.add('WebVTT cue layout is preserved in the original only');
      }
      var payload = rows.skip(i + 1).join('\n').replaceFirst(RegExp(r'\n+$'), '');
      final partTag = RegExp(r'<v(?:\.[^ >]+)?\s+([^>]+)>').firstMatch(payload)?[1];
      final part = partTag == null ? null : _entities(partTag);
      var markerPrefix = '\u{F0000}PLEAZYNG_RUBY_';
      const markerSuffix = '\u{F0001}';
      while (payload.contains(markerPrefix)) {
        markerPrefix += '_';
      }
      final rubyParts = <String, List<String>>{};
      var rubyIndex = 0;
      final rubyPattern = RegExp(
        r'<ruby(?:\s+[^>]*)?>(.*?)<rt(?:\s+[^>]*)?>(.*?)</rt>\s*</ruby>',
        caseSensitive: false,
        dotAll: true,
      );
      payload = payload.replaceAllMapped(rubyPattern, (match) {
        final base = match[1]!, reading = match[2]!;
        if (base.isEmpty ||
            reading.isEmpty ||
            RegExp(r'<[^>]+>').hasMatch(base) ||
            RegExp(r'<[^>]+>').hasMatch(reading)) {
          return match[0]!;
        }
        final marker = '$markerPrefix${rubyIndex++}$markerSuffix';
        rubyParts[marker] = [_entities(base), _entities(reading)];
        return marker;
      });
      if (RegExp(r'<(?:ruby|rt|lang)\b', caseSensitive: false).hasMatch(payload)) {
        warnings.add('Unsupported ruby/language markup is preserved in the original only');
      }
      payload = payload.replaceAll(RegExp(r'</?[a-zA-Z][^>]*>'), '');
      final stamps = RegExp(r'<((?:\d+:)?\d{2}:\d{2}\.\d{3})>').allMatches(payload).toList();
      final spans = <LyricSpan>[];
      final rubyMarker = RegExp('${RegExp.escape(markerPrefix)}\\d+${RegExp.escape(markerSuffix)}');
      void appendTextSpans(String content, int begin, int? finish) {
        var offset = 0;
        for (final marker in rubyMarker.allMatches(content)) {
          final before = _entities(content.substring(offset, marker.start));
          if (before.isNotEmpty) {
            spans.add(LyricSpan(text: before, startMs: begin, endMs: finish, part: part));
          }
          final ruby = rubyParts[marker[0]!];
          if (ruby != null) {
            spans.add(LyricSpan(text: ruby[0], startMs: begin, endMs: finish, part: part, pronunciation: ruby[1]));
          }
          offset = marker.end;
        }
        final tail = _entities(content.substring(offset));
        if (tail.isNotEmpty) {
          spans.add(LyricSpan(text: tail, startMs: begin, endMs: finish, part: part));
        }
      }

      var cursor = 0, at = start;
      for (final stamp in stamps) {
        final next = _time(stamp[1]!);
        if (next <= at || next >= end) {
          throw const FormatException('Invalid WebVTT inline timestamp');
        }
        appendTextSpans(payload.substring(cursor, stamp.start), at, next);
        cursor = stamp.end;
        at = next;
      }
      appendTextSpans(payload.substring(cursor), at, end);
      final hasRuby = rubyParts.isNotEmpty;
      if (stamps.isEmpty && !hasRuby) {
        spans.clear();
      }
      final lineText = stamps.isNotEmpty || hasRuby ? spans.map((span) => span.text).join() : _entities(payload);
      lines.add(
        LyricLine(text: lineText, startMs: start, endMs: end, part: part, spans: spans.isEmpty ? const [] : spans),
      );
    }
    lines.sort((a, b) => a.startMs!.compareTo(b.startMs!));
    return KaraokeTextImport(Lyrics(synced: true, lines: lines), warnings: warnings.toList());
  }

  static KaraokeTextImport _ttml(String text) {
    if (RegExp(r'<!DOCTYPE|<!ENTITY', caseSensitive: false).hasMatch(text)) {
      throw const FormatException('DTD/entities are not allowed');
    }
    final doc = XmlDocument.parse(text);
    final root = doc.rootElement;
    if (root.name.local != 'tt') {
      throw const FormatException('Missing TTML root');
    }
    const ttmlNamespace = 'http://www.w3.org/ns/ttml';
    const metadataNamespace = 'http://www.w3.org/ns/ttml#metadata';
    const xmlNamespace = 'http://www.w3.org/XML/1998/namespace';
    final warnings = <String>{};
    for (final e in root.descendants.whereType<XmlElement>()) {
      if (e.getAttribute('timeContainer') == 'seq') {
        throw const FormatException('Sequential TTML containers are not supported');
      }
      if (const {'image', 'audio', 'animate', 'set'}.contains(e.name.local)) {
        throw const FormatException('TTML media/animation is not supported');
      }
      if (e.attributes.any((a) => a.name.prefix == 'tts') ||
          e.getAttribute('style') != null ||
          e.getAttribute('region') != null) {
        warnings.add('TTML styling is preserved in the original only');
      }
    }
    final declaredAgentIds = <String>{};
    final agentNames = <String, String>{};
    for (final agent in root.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'agent' && e.name.namespaceUri == metadataNamespace,
    )) {
      final parent = agent.parent;
      final head = parent is XmlElement && parent.name.local == 'metadata' ? parent.parent : parent;
      final significant =
          head is XmlElement &&
          head.name.local == 'head' &&
          head.name.namespaceUri == ttmlNamespace &&
          parent is XmlElement &&
          ((parent.name.local == 'head' && parent.name.namespaceUri == ttmlNamespace) ||
              (parent.name.local == 'metadata' && parent.name.namespaceUri == ttmlNamespace));
      if (!significant) {
        continue;
      }
      final id = agent.getAttribute('id', namespaceUri: xmlNamespace);
      if (id == null) {
        continue;
      }
      declaredAgentIds.add(id);
      for (final child in agent.children.whereType<XmlElement>()) {
        if (child.name.local == 'name' && child.name.namespaceUri == metadataNamespace) {
          agentNames[id] = child.innerText;
          break;
        }
      }
    }
    String? part(XmlElement element) {
      final value = element.getAttribute('agent', namespaceUri: metadataNamespace);
      if (value == null) {
        return null;
      }
      final references = value.trim().split(RegExp(r'\s+'));
      if (references.length > 1 && references.any(declaredAgentIds.contains)) {
        throw const FormatException(
          'Multiple TTML agent references cannot be represented by a single karaoke part label',
        );
      }
      if (references.length == 1) {
        return agentNames[references.first] ?? value;
      }
      return value;
    }

    int begin(XmlElement e) {
      final parent = e.parent;
      return (parent is XmlElement ? begin(parent) : 0) +
          (e.getAttribute('begin') == null ? 0 : _time(e.getAttribute('begin')!));
    }

    int? end(XmlElement e) {
      final parent = e.parent;
      final parentStart = parent is XmlElement ? begin(parent) : 0;
      final parentEnd = parent is XmlElement ? end(parent) : null;
      final values = <int>[
        ?parentEnd,
        if (e.getAttribute('end') != null) parentStart + _time(e.getAttribute('end')!),
        if (e.getAttribute('dur') != null) begin(e) + _time(e.getAttribute('dur')!),
      ];
      return values.isEmpty ? null : values.reduce(math.min);
    }

    final lines = <LyricLine>[];
    for (final p in root.descendants.whereType<XmlElement>().where((e) => e.name.local == 'p')) {
      final spans = <LyricSpan>[];
      void visit(XmlNode node, XmlElement owner) {
        if (node is XmlText) {
          spans.add(LyricSpan(text: node.value, startMs: begin(owner), endMs: end(owner), part: part(owner)));
        } else if (node is XmlElement) {
          if (node.name.local == 'br') {
            spans.add(LyricSpan(text: '\n', startMs: begin(owner), endMs: end(owner)));
          } else {
            for (final child in node.children) {
              visit(child, node);
            }
          }
        }
      }

      for (final child in p.children) {
        visit(child, p);
      }
      lines.add(
        LyricLine(text: spans.map((s) => s.text).join(), startMs: begin(p), endMs: end(p), spans: spans, part: part(p)),
      );
    }
    final orderedLines = lines.indexed.toList()
      ..sort((a, b) {
        final timeOrder = a.$2.startMs!.compareTo(b.$2.startMs!);
        return timeOrder == 0 ? a.$1.compareTo(b.$1) : timeOrder;
      });
    return KaraokeTextImport(
      Lyrics(synced: true, lines: orderedLines.map((entry) => entry.$2).toList()),
      warnings: warnings.toList(),
    );
  }

  static KaraokeTextImport _ultraStar(String text) {
    final meta = <String, String>{};
    for (final row in text.split('\n')) {
      final m = RegExp(r'^#([^:]+):(.*)$').firstMatch(row.trim());
      if (m != null) {
        meta[m[1]!.toUpperCase()] = m[2]!;
      }
    }
    if (meta['RELATIVE']?.toUpperCase() == 'YES') {
      throw const FormatException('Convert relative UltraStar charts to absolute timing before import');
    }
    if ((meta['VERSION'] ?? '1').startsWith('2')) {
      throw const FormatException('UltraStar v2 uses a different beat grid; convert to v1 before import');
    }
    final bpm = double.tryParse((meta['BPM'] ?? '').replaceAll(',', '.')) ?? 0;
    final gap = double.tryParse(meta['GAP'] ?? '0') ?? 0;
    if (!bpm.isFinite || bpm <= 0 || bpm > 10000 || !gap.isFinite) {
      throw const FormatException('Invalid UltraStar BPM/GAP');
    }
    int ms(int beat) => (gap + beat * 15000 / bpm).round();
    final notes = <KaraokeNote>[], lines = <LyricLine>[];
    var part = '1';
    final phrase = <KaraokeNote>[];
    void flush() {
      if (phrase.isEmpty) {
        return;
      }
      lines.add(
        LyricLine(
          text: phrase.map((n) => n.text).join(),
          startMs: phrase.first.startMs,
          endMs: phrase.last.endMs,
          part: part,
          spans: phrase
              .map(
                (n) =>
                    LyricSpan(text: n.text, startMs: n.startMs, endMs: n.endMs, unit: LyricUnit.syllable, part: part),
              )
              .toList(),
        ),
      );
      phrase.clear();
    }

    for (final row in text.split('\n')) {
      final r = row.trimRight();
      if (r.startsWith('P')) {
        flush();
        part = r.substring(1).trim();
        continue;
      }
      if (r.startsWith('-') || r == 'E') {
        flush();
        continue;
      }
      final m = RegExp(r'^([:*FRG])\s+(-?\d+)\s+(\d+)\s+(-?\d+)\s?(.*)$').firstMatch(r);
      if (m == null) {
        continue;
      }
      final start = ms(int.parse(m[2]!)), end = ms(int.parse(m[2]!) + int.parse(m[3]!));
      final midi = int.parse(m[4]!) + 60; // UltraStar pitch zero is C4.
      if (start < 0 || end <= start || midi < 0 || midi > 127) {
        throw const FormatException('Invalid UltraStar note');
      }
      final n = KaraokeNote(
        startMs: start,
        endMs: end,
        midi: midi.toDouble(),
        part: part,
        text: m[5]!,
        golden: m[1] == '*' || m[1] == 'G',
        freestyle: m[1] == 'F' || m[1] == 'R' || m[1] == 'G',
      );
      notes.add(n);
      phrase.add(n);
    }
    flush();
    lines.sort((a, b) => a.startMs!.compareTo(b.startMs!));
    return KaraokeTextImport(
      Lyrics(synced: true, lines: lines),
      notes: notes,
      metadata: meta,
      warnings: const ['Imported note charts require review before scoring'],
    );
  }

  static String _stamp(int ms) =>
      '${(ms ~/ 3600000).toString().padLeft(2, '0')}:${(ms ~/ 60000 % 60).toString().padLeft(2, '0')}:${(ms ~/ 1000 % 60).toString().padLeft(2, '0')}.${(ms % 1000).toString().padLeft(3, '0')}';
  static String _escape(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  static String _escapeXmlText(String value) {
    if (value.runes.any(
      (rune) =>
          rune != 0x09 &&
          rune != 0x0a &&
          rune != 0x0d &&
          (rune < 0x20 || (rune >= 0xd800 && rune <= 0xdfff) || rune == 0xfffe || rune == 0xffff),
    )) {
      throw const FormatException('TTML cannot encode characters that are invalid in XML 1.0');
    }
    return _escape(value);
  }

  static void _requireRepresentable(
    Lyrics lyrics,
    String format, {
    required bool supportsLineParts,
    required bool supportsExplicitLineEnds,
    required bool supportsCueEndForLastSpan,
    required bool supportsSpanPronunciation,
  }) {
    final losses = <String>{};
    for (var i = 0; i < lyrics.lines.length; i++) {
      final line = lyrics.lines[i];
      final nextLineStart = i + 1 < lyrics.lines.length ? lyrics.lines[i + 1].startMs : null;
      final cueEnd = line.endMs ?? nextLineStart;
      if (line.translation != null) {
        losses.add('line translations');
      }
      if (line.pronunciation != null) {
        losses.add('line pronunciations');
      }
      if (line.part != null && !supportsLineParts) {
        losses.add('duet part labels');
      }
      if (!supportsExplicitLineEnds && line.endMs != null && line.endMs != nextLineStart) {
        losses.add('explicit line end times');
      }
      if (line.spans.isNotEmpty && line.spans.map((span) => span.text).join() != line.text) {
        losses.add('lyric text outside timed spans');
      }
      if (line.startMs == null && line.spans.isNotEmpty) {
        losses.add('timed spans on untimed lines');
      }

      for (var j = 0; j < line.spans.length; j++) {
        final span = line.spans[j];
        if (!supportsSpanPronunciation && (span.pronunciation?.trim().isNotEmpty ?? false)) {
          losses.add('per-span pronunciation readings');
        }
        if (span.unit != LyricUnit.word) {
          losses.add('syllable or token units');
        }
        if (span.confidence != null) {
          losses.add('span confidence values');
        }
        if (span.part != null && span.part != line.part) {
          losses.add('per-span duet part labels');
        }
        if (line.startMs != null && span.startMs < line.startMs!) {
          losses.add('span starts before their cue');
        }
        int? impliedEnd;
        for (var next = j + 1; next < line.spans.length; next++) {
          if (line.spans[next].startMs != span.startMs) {
            impliedEnd = line.spans[next].startMs;
            break;
          }
        }
        if (impliedEnd == null && supportsCueEndForLastSpan) {
          impliedEnd = cueEnd;
        }
        if (span.endMs != null && span.endMs != impliedEnd) {
          losses.add('explicit span end times');
        }
        if (format == 'WebVTT' && cueEnd != null && span.startMs >= cueEnd) {
          losses.add('span starts at or after their cue end');
        }
      }
    }
    if (losses.isNotEmpty) {
      throw FormatException(
        '$format cannot preserve ${losses.join(', ')}. Export a native karaoke package to keep them.',
      );
    }
  }

  static String exportVtt(Lyrics lyrics) {
    _requireRepresentable(
      lyrics,
      'WebVTT',
      supportsLineParts: true,
      supportsExplicitLineEnds: true,
      supportsCueEndForLastSpan: true,
      supportsSpanPronunciation: true,
    );
    final out = StringBuffer('WEBVTT\n\n');
    for (var i = 0; i < lyrics.lines.length; i++) {
      final line = lyrics.lines[i];
      if (line.startMs == null) {
        throw const FormatException('Untimed lyrics cannot be exported as timed cues');
      }
      final end = line.endMs ?? (i + 1 < lyrics.lines.length ? lyrics.lines[i + 1].startMs : null);
      if (end == null || end <= line.startMs!) {
        throw const FormatException('Set every cue end time before exporting');
      }
      out.writeln('${_stamp(line.startMs!)} --> ${_stamp(end)}');
      if (line.part != null) {
        out.write('<v ${_escape(line.part!)}>');
      }
      if (line.spans.isEmpty) {
        out.write(_escape(line.text));
      } else {
        for (final s in line.spans) {
          if (s.startMs > line.startMs! && s.startMs < end) {
            out.write('<${_stamp(s.startMs)}>');
          }
          final pronunciation = s.pronunciation;
          if (pronunciation != null && pronunciation.trim().isNotEmpty) {
            out.write('<ruby>${_escape(s.text)}<rt>${_escape(pronunciation)}</rt></ruby>');
          } else {
            out.write(_escape(s.text));
          }
        }
      }
      if (line.part != null) {
        out.write('</v>');
      }
      out.writeln();
      out.writeln();
    }
    return out.toString();
  }

  static String exportTtml(Lyrics lyrics) {
    if (!lyrics.synced) {
      throw const FormatException('Untimed lyrics cannot be exported as TTML');
    }
    final losses = <String>{};
    var previousStart = -1;
    for (final line in lyrics.lines) {
      final start = line.startMs;
      if (start == null) {
        losses.add('untimed lines');
        continue;
      }
      if (start < 0 || start > _maxPreciseTimeMs) {
        throw const FormatException('TTML line time exceeds the supported precise millisecond range');
      }
      if (start < previousStart) {
        losses.add('line order that differs from chronological order');
      }
      previousStart = start;
      if (line.endMs != null && (line.endMs! <= start || line.endMs! > _maxPreciseTimeMs)) {
        throw const FormatException('TTML line end must follow its start and stay within the supported time range');
      }
      if (line.translation != null) {
        losses.add('line translations');
      }
      if (line.pronunciation != null) {
        losses.add('line pronunciations');
      }
      if (line.spans.isNotEmpty && line.spans.map((span) => span.text).join() != line.text) {
        losses.add('lyric text outside timed spans');
      }
      for (final span in line.spans) {
        if (span.text.isEmpty) {
          losses.add('empty timed spans');
        }
        if (span.pronunciation != null) {
          losses.add('span pronunciation readings');
        }
        if (span.unit != LyricUnit.word) {
          losses.add('syllable or token units');
        }
        if (span.confidence != null) {
          losses.add('span confidence values');
        }
        if (span.startMs < start) {
          throw const FormatException('TTML span starts cannot precede their line');
        }
        if (span.startMs > _maxPreciseTimeMs) {
          throw const FormatException('TTML span start exceeds the supported precise millisecond range');
        }
        if (span.endMs == null && line.endMs != null) {
          losses.add('span ends inherited from a line end');
        }
        if (line.endMs != null && span.startMs >= line.endMs!) {
          throw const FormatException('TTML span starts must precede their line end');
        }
        if (span.endMs != null && span.endMs! <= span.startMs) {
          throw const FormatException('TTML span ends must follow their starts');
        }
        if (span.endMs != null && line.endMs != null && span.endMs! > line.endMs!) {
          throw const FormatException('TTML span ends cannot follow their line end');
        }
        if (span.endMs != null && span.endMs! > _maxPreciseTimeMs) {
          throw const FormatException('TTML span end exceeds the supported precise millisecond range');
        }
      }
    }
    if (losses.isNotEmpty) {
      throw FormatException('TTML cannot preserve ${losses.join(', ')}. Export a native karaoke package to keep them.');
    }

    final agentIds = <String, String>{};
    for (final line in lyrics.lines) {
      for (final label in [line.part, ...line.spans.map((span) => span.part)]) {
        if (label == null) {
          continue;
        }
        if (label.isEmpty) {
          throw const FormatException('TTML part labels cannot be empty');
        }
        agentIds.putIfAbsent(label, () => 'agent${agentIds.length + 1}');
      }
    }

    final out = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<tt xmlns="http://www.w3.org/ns/ttml" '
      'xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:space="preserve">\n',
    );
    if (agentIds.isNotEmpty) {
      out.write('  <head>\n    <metadata>\n');
    }
    for (final entry in agentIds.entries) {
      out.write(
        '      <ttm:agent type="group" xml:id="${entry.value}">'
        '<ttm:name>${_escapeXmlText(entry.key)}</ttm:name></ttm:agent>\n',
      );
    }
    if (agentIds.isNotEmpty) {
      out.write('    </metadata>\n  </head>\n');
    }
    out.write('  <body>\n    <div>\n');
    for (final line in lyrics.lines) {
      final start = line.startMs!;
      out.write('      <p begin="${_stamp(start)}"');
      if (line.endMs != null) {
        out.write(' dur="${_stamp(line.endMs! - start)}"');
      }
      if (line.part != null) {
        out.write(' ttm:agent="${agentIds[line.part!]}"');
      }
      out.write('>');
      if (line.spans.isEmpty) {
        out.write(_escapeXmlText(line.text));
      } else {
        for (final span in line.spans) {
          out.write('<span begin="${_stamp(span.startMs - start)}"');
          if (span.endMs != null) {
            out.write(' dur="${_stamp(span.endMs! - span.startMs)}"');
          }
          if (span.part != null) {
            out.write(' ttm:agent="${agentIds[span.part!]}"');
          }
          out.write('>${_escapeXmlText(span.text)}</span>');
        }
      }
      out.writeln('</p>');
    }
    out.write('    </div>\n  </body>\n</tt>\n');
    return out.toString();
  }

  static String exportLrc(Lyrics lyrics) {
    _requireRepresentable(
      lyrics,
      'LRC',
      supportsLineParts: false,
      supportsExplicitLineEnds: false,
      supportsCueEndForLastSpan: false,
      supportsSpanPronunciation: false,
    );
    return lyrics.lines
        .map((l) {
          String stamp(int ms) =>
              '${(ms ~/ 60000).toString().padLeft(2, '0')}:${(ms ~/ 1000 % 60).toString().padLeft(2, '0')}.${(ms % 1000).toString().padLeft(3, '0')}';
          return l.startMs == null
              ? l.text
              : '[${stamp(l.startMs!)}]${l.spans.isEmpty ? l.text : l.spans.map((s) => '<${stamp(s.startMs)}>${s.text}').join()}';
        })
        .join('\n');
  }
}
