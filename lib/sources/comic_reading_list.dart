import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import 'source_models.dart';

String _fold(String value) => value.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();
String _number(String value) => num.tryParse(value)?.toStringAsFixed(6) ?? _fold(value);

class ComicIssue {
  const ComicIssue(this.series, this.number, {this.volume = '', this.year = ''});
  final String series, number, volume, year;
  String get label => [
    series,
    if (volume.isNotEmpty) '($volume)',
    if (number.isNotEmpty) '#$number',
    if (year.isNotEmpty && year != volume) '($year)',
  ].join(' ');
  Map<String, String> toJson() => {'series': series, 'number': number, 'volume': volume, 'year': year};
  factory ComicIssue.fromJson(Map<String, dynamic> data) => ComicIssue(
    data['series'] as String,
    data['number'] as String,
    volume: data['volume'] as String? ?? '',
    year: data['year'] as String? ?? '',
  );

  static final _volumeSuffix = RegExp(r'\s+(?:\((\d{4})\)|\(?v(?:ol(?:ume)?\.?)?\s*(\d+)\)?)$', caseSensitive: false);

  ComicIssue get forMatching {
    final match = _volumeSuffix.firstMatch(series);
    if (match == null) return this;
    return ComicIssue(
      series.substring(0, match.start).trim(),
      number,
      volume: volume.isEmpty ? (match[1] ?? match[2]!) : volume,
      year: year,
    );
  }

  static ComicIssue? fromEntry(SourceEntry entry) {
    final filename = path.basenameWithoutExtension(entry.files.firstOrNull?.name ?? entry.title);
    final ids = entry.identifiers;
    final named = RegExp(
      r'^(.+?)(?:\s+\((\d{4})\)|\s+v(?:ol\.?\s*)?(\d+))?[\s._-]+#?(\d+(?:\.\d+)?[a-z]?)(?:\s*\((\d{4})\))?(?:\s*[\[(].*)?$',
      caseSensitive: false,
    ).firstMatch(filename);
    final series = entry.series.isEmpty ? named?.group(1) : entry.series;
    final number = ids['issueNumber'] ?? entry.seriesOrder?.toString() ?? named?[4];
    if (series == null || number == null) return null;
    final annual = RegExp(r'\bannual\b', caseSensitive: false);
    final annualInTitle = annual.hasMatch(filename) || annual.hasMatch(entry.title);
    final resolvedSeries = annualInTitle && !annual.hasMatch(series) ? '$series Annual' : series;
    return ComicIssue(
      resolvedSeries,
      number,
      volume: ids['seriesVolume'] ?? named?[2] ?? named?[3] ?? '',
      year: entry.releaseYear?.toString() ?? named?[5] ?? '',
    );
  }
}

class ComicIssueIndex {
  ComicIssueIndex(Iterable<SourceEntry> entries) {
    for (final entry in entries) {
      byKey[entry.key] = entry;
      final issue = ComicIssue.fromEntry(entry)?.forMatching;
      if (issue != null) (_issues[(_fold(issue.series), _number(issue.number))] ??= []).add((issue, entry));
    }
  }
  final byKey = <String, SourceEntry>{};
  final _issues = <(String, String), List<(ComicIssue, SourceEntry)>>{};
  SourceEntry? automatic(ComicIssue wanted, List<SourceEntry> candidates) {
    if (candidates.length != 1 || wanted.series.isEmpty || wanted.number.isEmpty) return null;
    wanted = wanted.forMatching;
    final found = ComicIssue.fromEntry(candidates.single)?.forMatching;
    if (found == null ||
        (wanted.volume.isNotEmpty && _fold(found.volume) != _fold(wanted.volume)) ||
        (wanted.year.isNotEmpty && found.year != wanted.year)) {
      return null;
    }
    return candidates.single;
  }

  List<SourceEntry> matches(ComicIssue wanted) {
    wanted = wanted.forMatching;
    final matches = _issues[(_fold(wanted.series), _number(wanted.number))] ?? [];
    return [
      for (final (issue, entry) in matches)
        if ((wanted.volume.isEmpty || issue.volume.isEmpty || _fold(wanted.volume) == _fold(issue.volume)) &&
            (wanted.year.isEmpty || issue.year.isEmpty || wanted.year == issue.year))
          entry,
    ];
  }
}

class ComicReadingList {
  ComicReadingList(this.title, this.issues);
  final String title;
  final List<ComicIssue> issues;
  static const maxBytes = 4 * 1024 * 1024;
  factory ComicReadingList.parse(List<int> bytes, String filename) {
    if (bytes.length > maxBytes) throw const FormatException('CBL exceeds size limit');
    final little = bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe;
    final big = bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff;
    if ((little || big) && bytes.length.isOdd) throw const FormatException('Truncated UTF-16 XML');
    final source = little || big
        ? String.fromCharCodes([
            for (var i = 2; i < bytes.length; i += 2)
              little ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1],
          ])
        : utf8.decode(bytes);
    if (RegExp(r'<!DOCTYPE', caseSensitive: false).hasMatch(source)) {
      throw const FormatException('Unexpected CBL declaration');
    }
    final root = XmlDocument.parse(source).rootElement;
    final books = root.getElement('Books');
    if (root.name.local != 'ReadingList' || books == null) throw const FormatException('Invalid reading list');
    final issues = <ComicIssue>[];
    for (final book in books.findElements('Book')) {
      String attr(String name) => book.getAttribute(name)?.trim() ?? '';
      issues.add(ComicIssue(attr('Series'), attr('Number'), volume: attr('Volume'), year: attr('Year')));
      if (issues.length > 10000) throw const FormatException('Too many issues');
    }
    if (issues.isEmpty) throw const FormatException('Empty reading list');
    final name = root.getElement('Name')?.innerText.trim() ?? '';
    return ComicReadingList(name.isEmpty ? path.basenameWithoutExtension(filename) : name, issues);
  }
  Map<String, dynamic> toJson() => {
    'title': title,
    'issues': [for (final issue in issues) issue.toJson()],
  };
  factory ComicReadingList.fromJson(Map<String, dynamic> data) => ComicReadingList(data['title'] as String, [
    for (final issue in data['issues'] as List) ComicIssue.fromJson(sourceMap(issue)),
  ]);
}
