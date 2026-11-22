import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../i18n/presentation_formats.dart';
import '../../services/file_picker_service.dart';
import '../../sources/podcast_opml.dart';
import '../../sources/source_controller.dart';
import '../../sources/source_models.dart';
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/dialog_action_button.dart';

Future<void> importPodcastOpml(BuildContext context) async {
  final sources = context.read<SourceController>();
  sources.requireSession();
  final epoch = sources.generation;
  final picked = await FilePickerService.instance.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['opml', 'xml'],
    withData: true,
  );
  sources.requireSession(epoch);
  final bytes = picked?.files.firstOrNull?.bytes;
  if (bytes == null || bytes.isEmpty) return;
  if (bytes.length > PodcastOpml.maxBytes) throw const SourceException(SourceFailure.invalidData);
  final preview = PodcastOpml.preview(utf8.decode(bytes));
  final httpFeeds = preview.feeds.where((feed) => feed.url.scheme == 'http').toList();
  if (!context.mounted) return;
  final approved = httpFeeds.isEmpty ? <Uri>{} : await _reviewHttpFeeds(context, httpFeeds);
  if (approved == null || !context.mounted) return;
  sources.requireSession(epoch);
  final selected = preview.feeds.where((feed) => feed.url.scheme == 'https' || approved.contains(feed.url)).toList();
  final count = selected.isEmpty
      ? 0
      : await sources.importPodcastSubscriptions(selected, approvedHttpFeeds: approved, expectedGeneration: epoch);
  sources.requireSession(epoch);
  if (context.mounted) {
    String number(int n) => formatDecimal(n, maximumDecimals: 0);
    showSnackBar(
      context,
      t.podcasts.importSummary(
        imported: number(count),
        duplicates: number(preview.duplicates + selected.length - count),
        skipped: number(preview.invalid + httpFeeds.length - approved.length),
      ),
    );
  }
}

Future<Set<Uri>?> _reviewHttpFeeds(BuildContext context, List<PodcastSubscription> feeds) {
  final selected = <Uri>{};
  final revealed = <Uri>{};
  return showScopedDialog<Set<Uri>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(t.fileSources.allowHttp),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.universalMedia.allowHttpHelp),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: feeds.length,
                  itemBuilder: (context, index) {
                    final feed = feeds[index];
                    final url = feed.url;
                    final showFull = revealed.contains(url);
                    final address = url.toString();
                    return Row(
                      children: [
                        Expanded(
                          child: CheckboxListTile(
                            title: Text(feed.title),
                            subtitle: Text(url.hasQuery && !showFull ? '${address.split('?').first}?…' : address),
                            value: selected.contains(feed.url),
                            onChanged: (checked) => update(() {
                              if (checked == true) {
                                selected.add(feed.url);
                              } else {
                                selected.remove(feed.url);
                              }
                            }),
                          ),
                        ),
                        if (url.hasQuery)
                          IconButton(
                            tooltip: showFull ? t.startup.hideDetails : t.startup.showDetails,
                            icon: Icon(showFull ? Icons.visibility_off : Icons.visibility),
                            onPressed: () => update(() {
                              if (showFull) {
                                revealed.remove(url);
                              } else {
                                revealed.add(url);
                              }
                            }),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          DialogActionButton(autofocus: true, label: t.common.cancel, onPressed: () => Navigator.pop(context)),
          DialogActionButton(
            isPrimary: true,
            label: t.podcasts.importOpml,
            onPressed: () => Navigator.pop(context, selected),
          ),
        ],
      ),
    ),
  );
}

Future<void> exportPodcastOpml(BuildContext context) async {
  final sources = context.read<SourceController>();
  sources.requireSession();
  final epoch = sources.generation;
  final subscriptions = await sources.podcastSubscriptions();
  sources.requireSession(epoch);
  if (subscriptions.isEmpty || !context.mounted) return;
  if (!await showConfirmDialog(
    context,
    title: t.podcasts.exportOpml,
    message: t.podcasts.exportHelp,
    confirmText: t.podcasts.exportOpml,
  )) {
    return;
  }
  sources.requireSession(epoch);
  await FilePickerService.instance.saveFile(
    fileName: 'plezyng-podcasts.opml',
    type: FileType.custom,
    allowedExtensions: const ['opml'],
    bytes: Uint8List.fromList(utf8.encode(PodcastOpml.write(subscriptions))),
  );
}
