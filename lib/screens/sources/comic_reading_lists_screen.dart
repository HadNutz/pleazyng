import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../sources/comic_reading_list.dart';
import '../../sources/publication_shelf.dart';
import '../../sources/source_controller.dart';
import '../../sources/source_models.dart';
import '../../utils/snackbar_helper.dart';
import 'publication_reader_screen.dart';

const _readingListExtension = 'cbl';

class ComicReadingListsScreen extends StatelessWidget {
  const ComicReadingListsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final profile = context.select((SourceController s) => s.profileId);
    return profile == null
        ? Scaffold(appBar: AppBar(title: Text(t.comics.readLists)))
        : _ReadingLists(key: ValueKey(profile), profile: profile);
  }
}

class _ReadingLists extends StatefulWidget {
  const _ReadingLists({super.key, required this.profile});
  final String profile;
  @override
  State<_ReadingLists> createState() => _ReadingListsState();
}

class _ReadingListsState extends State<_ReadingLists> {
  static const pref = 'importedComicReadingLists.v1';
  Map<String, dynamic> lists = {};
  ComicIssueIndex index = ComicIssueIndex([]);
  Map<String, PublicationProgress> progress = {};
  String? selected;
  bool loading = true;
  int revision = 0;
  bool valid(SourceController sources, int epoch) => sources.current(epoch) && sources.profileId == widget.profile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sources = context.read<SourceController>(), epoch = sources.generation, token = ++revision;
    try {
      final saved = await sources.repository.preference(widget.profile, pref);
      final entries = <SourceEntry>[];
      String? cursor;
      do {
        if (!mounted || !valid(sources, epoch) || token != revision) return;
        final page = await sources.repository.entriesPage(
          widget.profile,
          shelf: PublicationShelf.comics,
          cursor: cursor,
          limit: 500,
        );
        entries.addAll(page.items.where((e) => e.ebooks.any((f) => f.kind == SourceItemKind.comic)));
        cursor = page.cursor;
      } while (cursor != null);
      final states = await sources.repository.progressForEntries(widget.profile, entries.map((e) => e.key));
      if (!mounted || !valid(sources, epoch) || token != revision) return;
      setState(() {
        lists = saved;
        index = ComicIssueIndex(entries);
        progress = {
          for (final p in states)
            if (p.mode == PublicationMode.reading) p.entryKey: p,
        };
        loading = false;
      });
    } catch (_) {
      if (mounted && valid(sources, epoch)) {
        setState(() => loading = false);
        showErrorSnackBar(context, t.fileSources.errorUnavailable);
      }
    }
  }

  Future<void> _import() async {
    final sources = context.read<SourceController>(), epoch = sources.generation;
    try {
      final pick = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [_readingListExtension],
        withReadStream: true,
      );
      if (!mounted || !valid(sources, epoch) || pick == null) return;
      final file = pick.files.single;
      if (file.size > ComicReadingList.maxBytes) throw const FormatException();
      final bytes = <int>[];
      if (file.readStream != null) {
        await for (final part in file.readStream!) {
          if (bytes.length + part.length > ComicReadingList.maxBytes) throw const FormatException();
          bytes.addAll(part);
        }
      } else {
        bytes.addAll(file.bytes ?? const []);
      }
      final list = ComicReadingList.parse(bytes, file.name);
      final data = list.toJson();
      final id = sha256.convert(utf8.encode(jsonEncode(data))).toString();
      if (!mounted || !valid(sources, epoch)) return;
      final saved = await sources.repository.updatePreferenceAtomically(
        widget.profile,
        pref,
        (all) => all..putIfAbsent(id, () => data),
      );
      if (mounted && valid(sources, epoch)) {
        setState(() {
          lists = saved;
          selected = id;
        });
      }
    } catch (_) {
      if (mounted && valid(sources, epoch)) showErrorSnackBar(context, t.fileSources.errorInvalidData);
    }
  }

  Future<void> _resolve(int position, ComicIssue issue, List<SourceEntry> matches) async {
    final sources = context.read<SourceController>(), epoch = sources.generation, id = selected!;
    final choice = await Navigator.push<SourceEntry>(
      context,
      MaterialPageRoute(
        builder: (_) => _ComicPicker(
          issue: issue,
          candidates: matches,
          entries: index.byKey.values.toList(),
          names: {for (final s in sources.sources) s.id: s.name},
        ),
      ),
    );
    if (choice == null || !mounted || !valid(sources, epoch)) return;
    try {
      final saved = await sources.repository.updatePreferenceAtomically(widget.profile, pref, (all) {
        if (!all.containsKey(id)) return all;
        final data = sourceMap(all[id]);
        data['overrides'] = {...sourceMap(data['overrides']), '$position': choice.key};
        return all..[id] = data;
      });
      if (mounted && valid(sources, epoch)) setState(() => lists = saved);
    } catch (_) {
      if (mounted && valid(sources, epoch)) showErrorSnackBar(context, t.fileSources.errorUnavailable);
    }
  }

  Future<void> _remove(String id, String title) async {
    final sources = context.read<SourceController>(), epoch = sources.generation;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.common.delete)),
        ],
      ),
    );
    if (confirm != true || !mounted || !valid(sources, epoch)) return;
    try {
      final saved = await sources.repository.updatePreferenceAtomically(widget.profile, pref, (all) => all..remove(id));
      if (mounted && valid(sources, epoch)) {
        setState(() {
          lists = saved;
          selected = null;
        });
      }
    } catch (_) {
      if (mounted && valid(sources, epoch)) showErrorSnackBar(context, t.fileSources.errorUnavailable);
    }
  }

  Future<void> _read(SourceEntry entry) async {
    final file = entry.ebooks.firstWhere((f) => f.kind == SourceItemKind.comic);
    await Navigator.push(
      context,
      PageRouteBuilder<void>(
        opaque: false,
        settings: const RouteSettings(name: 'publication-reader'),
        pageBuilder: (_, _, _) => PublicationReaderScreen(entry: entry, file: file),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final importLabel = '${t.fileSources.importFiles} (.$_readingListExtension)';
    final data = sourceMap(lists[selected]);
    final list = data.isEmpty ? null : ComicReadingList.fromJson(data);
    final overrides = sourceMap(data['overrides']);
    final rows = [
      if (list != null)
        for (final (i, issue) in list.issues.indexed)
          () {
            final matches = index.matches(issue), pinned = overrides['$i'];
            final entry = pinned is String ? index.byKey[pinned] : index.automatic(issue, matches);
            return (
              issue: issue,
              matches: matches,
              entry: entry,
              finished: entry != null && progress[entry.key]?.finished == true,
            );
          }(),
    ];
    final next = rows.indexWhere((r) => !r.finished);
    void open(int i) {
      final row = rows[i];
      if (row.entry != null) {
        _read(row.entry!);
      } else {
        _resolve(i, row.issue, row.matches);
      }
    }

    return PopScope(
      canPop: list == null,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && mounted) setState(() => selected = null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(list?.title ?? t.comics.readLists),
          actions: [
            if (list != null)
              IconButton(
                tooltip: t.common.delete,
                icon: const AppIcon(Symbols.delete_rounded),
                onPressed: () => _remove(selected!, list.title),
              ),
            if (list == null)
              IconButton(tooltip: importLabel, icon: const AppIcon(Symbols.file_open_rounded), onPressed: _import),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : list == null
            ? (lists.isEmpty
                  ? Center(
                      child: OutlinedButton.icon(
                        onPressed: _import,
                        icon: const AppIcon(Symbols.file_open_rounded),
                        label: Text(importLabel),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final e in lists.entries)
                          ListTile(
                            title: Text(sourceMap(e.value)['title'] as String),
                            trailing: const AppIcon(Symbols.chevron_right_rounded),
                            onTap: () => setState(() => selected = e.key),
                          ),
                      ],
                    ))
            : Column(
                children: [
                  ListTile(
                    title: Text(next < 0 ? t.fileSources.finished : t.mediaConveniences.readNext),
                    subtitle: Text('${rows.where((r) => r.finished).length} / ${rows.length}'),
                    trailing: next < 0 ? null : const AppIcon(Symbols.menu_book_rounded),
                    onTap: next < 0 ? null : () => open(next),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (_, i) {
                        final row = rows[i], entry = row.entry;
                        return ListTile(
                          leading: row.finished ? const AppIcon(Symbols.check_rounded) : Text('${i + 1}'),
                          title: Text(row.issue.label),
                          subtitle: Text(
                            entry?.title ??
                                (row.matches.isEmpty
                                    ? t.fileSources.noMatches
                                    : '${row.matches.length} · ${t.romm.select}'),
                          ),
                          onTap: () => open(i),
                          trailing: IconButton(
                            tooltip: t.matchScreen.search,
                            icon: const AppIcon(Symbols.link_rounded),
                            onPressed: () => _resolve(i, row.issue, row.matches),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _ComicPicker extends StatefulWidget {
  const _ComicPicker({required this.issue, required this.candidates, required this.entries, required this.names});
  final ComicIssue issue;
  final List<SourceEntry> candidates, entries;
  final Map<String, String> names;
  @override
  State<_ComicPicker> createState() => _ComicPickerState();
}

class _ComicPickerState extends State<_ComicPicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final items = query.isEmpty && widget.candidates.isNotEmpty
        ? widget.candidates
        : widget.entries
              .where(
                (e) => '${e.series} ${e.title} ${e.seriesOrder ?? ''} ${e.files.firstOrNull?.name ?? ''}'
                    .toLowerCase()
                    .contains(query),
              )
              .toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.issue.label)),
      body: Column(
        children: [
          TextField(
            decoration: InputDecoration(prefixIcon: const AppIcon(Symbols.search_rounded), labelText: t.common.search),
            onChanged: (s) => setState(() => query = s.trim().toLowerCase()),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, i) {
                final item = items[i];
                return ListTile(
                  title: Text(item.title),
                  subtitle: Text(
                    [
                      widget.names[item.sourceId] ?? item.sourceId,
                      item.series,
                      item.files.firstOrNull?.name ?? '',
                    ].where((s) => s.isNotEmpty).join(' · '),
                  ),
                  onTap: () => Navigator.pop(context, item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
