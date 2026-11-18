import 'dart:async';

import 'package:flutter/material.dart';

import '../../../i18n/presentation_formats.dart';
import '../../../i18n/strings.g.dart';
import '../../../mpv/player/player.dart';
import '../../../services/playback_presentation.dart';
import '../../../utils/snackbar_helper.dart';

String _laneLabel(StereoLane value) => switch (value) {
  StereoLane.stereo => t.settings.audioChannelLimitStereo,
  StereoLane.left => t.livingRoom.left,
  StereoLane.right => t.livingRoom.right,
};

class PlaybackPresentationControl extends StatelessWidget {
  const PlaybackPresentationControl({super.key, required this.player, this.brightness = false});
  final Player player;
  final bool brightness;

  Future<void> _open(BuildContext context, PlaybackPresentation session, String key) async {
    final file = session.source()?.file;
    final wasPlaying = brightness && player.state.playing;
    var level = session.brightness, lane = session.lane;
    var valid = true;
    Timer? debounce;
    Future<void> preview() async {
      try {
        if (brightness) {
          await session.chooseBrightness(key, level);
        } else {
          await session.chooseLane(key, lane);
        }
      } catch (_) {
        valid = false;
        if (context.mounted) showErrorSnackBar(context, t.fileSources.errorUnsupported);
      }
    }

    try {
      if (wasPlaying) await player.pause();
      if (!context.mounted) return;
      final apply = await showDialog<bool>(
        context: context,
        barrierColor: brightness ? Colors.transparent : null,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) {
            return AlertDialog(
              alignment: brightness ? Alignment.topCenter : null,
              title: Text(brightness ? t.mediaConveniences.hdrBrightness : t.mediaConveniences.stereoChannel),
              content: brightness
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(formatPercent(level / 100)),
                        Slider(
                          value: level.toDouble(),
                          min: 10,
                          max: 100,
                          divisions: 18,
                          label: formatPercent(level / 100),
                          onChanged: (v) {
                            update(() => level = v.round());
                            valid = true;
                            debounce?.cancel();
                            debounce = Timer(const Duration(milliseconds: 60), preview);
                          },
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final choice in StereoLane.values)
                          ListTile(
                            selected: choice == lane,
                            leading: Icon(choice == lane ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                            title: Text(_laneLabel(choice)),
                            onTap: () {
                              update(() => lane = choice);
                              valid = true;
                              unawaited(preview());
                            },
                          ),
                      ],
                    ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.common.cancel)),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.common.save)),
              ],
            );
          },
        ),
      );
      debounce?.cancel();
      if (session.source()?.file != file) {
        if (brightness) await session.chooseBrightness(key, null);
        return;
      }
      if (brightness) {
        await session.chooseBrightness(key, apply == true && valid ? level : null, save: apply == true && valid);
      } else {
        await session.chooseLane(key, apply == true && valid ? lane : null, save: apply == true && valid);
      }
    } catch (_) {
      if (context.mounted) showErrorSnackBar(context, t.fileSources.errorUnsupported);
    } finally {
      debounce?.cancel();
      if (wasPlaying && context.mounted && session.source()?.file == file && !player.state.playing) await player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = PlaybackPresentation.of(player);
    if (session == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final key = brightness ? session.hdrKey : session.stereoKey;
        if (key == null) return const SizedBox.shrink();
        return ListTile(
          leading: Icon(brightness ? Icons.brightness_6_outlined : Icons.speaker_group_outlined),
          title: Text(brightness ? t.mediaConveniences.hdrBrightness : t.mediaConveniences.stereoChannel),
          subtitle: Text(brightness ? formatPercent(session.brightness / 100) : _laneLabel(session.lane)),
          onTap: () => _open(context, session, key),
        );
      },
    );
  }
}
