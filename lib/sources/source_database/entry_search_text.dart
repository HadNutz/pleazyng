part of '../source_database.dart';

String _entrySearchText(SourceEntry entry) => [
  entry.title,
  entry.displayTitle,
  entry.onlineTitle,
  entry.author,
  entry.narrator,
  entry.series,
  ...entry.identifiers.entries.expand((value) => [value.key, value.value]),
].whereType<String>().join(' ').toLowerCase();
