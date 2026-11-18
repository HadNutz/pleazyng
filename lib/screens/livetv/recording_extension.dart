import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../iptv/iptv_models.dart';
import '../../iptv/iptv_recording_scheduler.dart';
import '../../utils/snackbar_helper.dart';

Future<void> extendIptvRecording(BuildContext context, IptvLocalRecordingSchedule schedule) async {
  DateTime? end;
  try {
    end = await context.read<IptvRecordingScheduler>().extend(schedule);
  } on Object {
    // Both a finished capture and a failed durable update leave the old deadline.
  }
  if (!context.mounted) return;
  showSnackBar(
    context,
    end == null
        ? t.viewing.extendFailed
        : t.viewing.recordsUntil(time: TimeOfDay.fromDateTime(end.toLocal()).format(context)),
  );
}

class LiveRecordingExtension extends StatelessWidget {
  const LiveRecordingExtension({
    super.key,
    required this.profile,
    required this.source,
    required this.channel,
    this.fallback,
  });
  final String? profile, source, channel;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    final scheduler = context.read<IptvRecordingScheduler?>();
    if (scheduler == null) return fallback ?? const SizedBox.shrink();
    return ValueListenableBuilder<int>(
      valueListenable: scheduler.changes,
      builder: (context, _, _) {
        final schedules = scheduler.activeFor(profile, source, channel).toList();
        if (schedules.isEmpty) return fallback ?? const SizedBox.shrink();
        final extension = schedules.length == 1
            ? IconButton(
                tooltip: t.viewing.extendRecording,
                icon: const AppIcon(Symbols.more_time_rounded, color: Colors.white),
                onPressed: () => extendIptvRecording(context, schedules.single),
              )
            : PopupMenuButton<IptvLocalRecordingSchedule>(
                tooltip: t.viewing.extendRecording,
                icon: const AppIcon(Symbols.more_time_rounded, color: Colors.white),
                onSelected: (schedule) => extendIptvRecording(context, schedule),
                itemBuilder: (_) => [
                  for (final s in schedules)
                    PopupMenuItem(
                      value: s,
                      child: Text('${t.viewing.extendRecording} · ${s.programmeTitle ?? s.title}'),
                    ),
                ],
              );
        return Row(mainAxisSize: MainAxisSize.min, children: [?fallback, extension]);
      },
    );
  }
}
