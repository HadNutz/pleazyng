import 'dart:convert';

import 'package:xml/xml.dart';

import '../models/livetv_channel.dart';
import '../models/livetv_program.dart';

/// Shared identifiers allow reimporting a playlist together with its XMLTV.
String _guideId(LiveTvChannel channel) =>
    channel.identifier?.trim().isNotEmpty == true ? channel.identifier! : channel.key;

String _oneLine(String value) => value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();

String m3uStation(LiveTvChannel channel, String address, {String? headers, String? catchup}) {
  final attributes = <String, String?>{
    'tvg-id': _guideId(channel),
    'tvg-chno': channel.number,
    'tvg-logo': channel.thumb,
    'group-title': channel.iptvGroupTitle,
    if (channel.iptvRadio) 'radio': 'true',
    if (catchup != null) 'catchup': 'default',
    'catchup-source': catchup,
    if (catchup != null) 'catchup-days': channel.iptvCatchupDays?.toString(),
  };
  final line = StringBuffer('#EXTINF:-1');
  for (final entry in attributes.entries) {
    final value = entry.value;
    if (value != null && value.isNotEmpty) {
      line.write(' ${entry.key}="${_oneLine(value).replaceAll('"', "'")}"');
    }
  }
  line.writeln(',${_oneLine(channel.title ?? channel.callSign ?? channel.key)}');
  if (headers != null) {
    final map = jsonDecode(headers) as Map<String, dynamic>;
    if (map.isNotEmpty) line.writeln('#EXTHTTP:${jsonEncode(map)}');
  }
  line.writeln(_oneLine(address));
  return line.toString();
}

String xmltvLineup(List<LiveTvChannel> channels, Iterable<LiveTvProgram> programmes) {
  final byGuideId = <String, LiveTvChannel>{};
  for (final channel in channels) {
    byGuideId.putIfAbsent(_guideId(channel), () => channel);
  }
  final byKey = {for (final entry in byGuideId.entries) entry.value.key: entry.key};
  String timestamp(int seconds) {
    final utc = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    return '${utc.toIso8601String().substring(0, 19).replaceAll(RegExp(r'[-T:]'), '')} +0000';
  }

  // The guide can contain hundreds of thousands of airings. Flush one XML
  // element at a time so the complete document never exists as a second DOM.
  final output = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv generator-info-name="Pleazyng">');
  final xml = XmlBuilder();
  for (final entry in byGuideId.entries) {
    final channel = entry.value;
    xml.element(
      'channel',
      attributes: {'id': _oneLine(entry.key)},
      nest: () {
        xml.element('display-name', nest: _oneLine(channel.title ?? channel.key));
        if (channel.thumb case final String logo) xml.element('icon', attributes: {'src': _oneLine(logo)});
      },
    );
    output.write(xml.buildFragment().children.single.toXmlString());
  }
  for (final p in programmes) {
    final id = byKey[p.channelIdentifier];
    final start = p.beginsAt, end = p.endsAt;
    if (id == null || start == null || end == null || end <= start) continue;
    xml.element(
      'programme',
      attributes: {'channel': _oneLine(id), 'start': timestamp(start), 'stop': timestamp(end)},
      nest: () {
        xml.element('title', nest: _oneLine(p.title));
        if (p.summary case final String description) xml.element('desc', nest: _oneLine(description));
        if (p.type case final String category) xml.element('category', nest: _oneLine(category));
        if (p.guid case final String episode) xml.element('episode-num', nest: _oneLine(episode));
        if (p.thumb case final String url) xml.element('icon', attributes: {'src': _oneLine(url)});
      },
    );
    output.write(xml.buildFragment().children.single.toXmlString());
  }
  output.write('</tv>');
  return output.toString();
}
