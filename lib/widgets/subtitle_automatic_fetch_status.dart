import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../services/subtitle_automatic_fetch.dart';

/// Small, accessible status surface for automatic preferred-subtitle lookup.
class SubtitleAutomaticFetchStatus extends StatelessWidget {
  const SubtitleAutomaticFetchStatus({super.key, required this.controller, this.onSearchAgain});

  final SubtitleAutomaticFetch controller;
  final VoidCallback? onSearchAgain;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final text = switch (controller.stage) {
        SubtitleFetchStage.idle || SubtitleFetchStage.completed => null,
        SubtitleFetchStage.searching ||
        SubtitleFetchStage.downloading ||
        SubtitleFetchStage.refreshing => t.common.loading,
        SubtitleFetchStage.noMatch => t.videoControls.noSubtitlesFound,
        SubtitleFetchStage.failed || SubtitleFetchStage.expired => t.common.error,
        SubtitleFetchStage.cancelled => null,
      };
      final showRetry = !controller.busy && onSearchAgain != null;
      if (text == null && !showRetry) return const SizedBox.shrink();

      return Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (text != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (controller.busy) ...[
                    const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                  ],
                  Flexible(
                    child: Semantics(liveRegion: true, child: Text(text, textAlign: TextAlign.center)),
                  ),
                ],
              ),
            if (controller.busy)
              TextButton(onPressed: controller.cancel, child: Text(t.common.cancel))
            else if (showRetry)
              TextButton(onPressed: onSearchAgain, child: Text(t.videoControls.searchSubtitles)),
          ],
        ),
      );
    },
  );
}
