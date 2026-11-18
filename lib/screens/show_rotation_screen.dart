import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/play_queue.dart';
import '../media/show_rotation.dart';
import '../providers/playback_state_provider.dart';
import '../providers/watch_state_store.dart';
import '../sources/source_controller.dart';
import '../sources/source_models.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../utils/video_player_navigation.dart';

class ShowRotationScreen extends StatefulWidget {
  const ShowRotationScreen({super.key, required this.show});
  final MediaItem show;
  @override
  State<ShowRotationScreen> createState() => _RotationState();
}

class _RotationState extends State<ShowRotationScreen> {
  static const preference = 'orderedShowRotation.v1';
  late final SourceController sources;
  late final String? profile;
  late final int epoch;
  Map<String, dynamic> data = {};
  Map<String, String> statuses = {};
  bool busy = true;
  bool get current => sources.current(epoch) && profile != null && sources.profileId == profile;
  Map<String, dynamic> get shows => sourceMap(data['shows']);
  @override
  void initState() {
    super.initState();
    sources = context.read<SourceController>();
    profile = sources.profileId;
    epoch = sources.generation;
    _load();
  }

  Future<void> _load() async {
    if (!mounted || !current) return;
    try {
      final result = await sources.repository.preference(profile!, preference);
      if (mounted && current) setState(() => data = result);
    } catch (_) {
      if (mounted && current) showErrorSnackBar(context, t.fileSources.errorUnavailable);
    } finally {
      if (mounted && current) setState(() => busy = false);
    }
  }

  Future<void> _toggle(String key) async {
    if (!mounted || !current || busy) return;
    setState(() => busy = true);
    try {
      final result = await sources.repository.updatePreferenceAtomically(profile!, preference, (state) {
        final members = sourceMap(state['shows']);
        if (members.containsKey(key)) {
          members.remove(key);
        } else {
          final show = widget.show;
          members[key] = {'id': show.id, 'server': show.serverId, 'title': show.title, 'serverName': show.serverName};
        }
        return {...state, 'shows': members};
      });
      if (mounted && current) setState(() => data = result);
    } catch (_) {
      if (mounted && current) showErrorSnackBar(context, t.fileSources.errorUnavailable);
    } finally {
      if (mounted && current) setState(() => busy = false);
    }
  }

  Future<void> _play() async {
    if (!mounted || !current || busy) return;
    setState(() => busy = true);
    try {
      final eligible = <String, List<MediaItem>>{}, messages = <String, String>{};
      Future<void> loadMember(MapEntry<String, dynamic> member) async {
        final m = sourceMap(member.value), server = m['server'] as String;
        if (!mounted || !current) return;
        final client = context.tryGetMediaClientForServer(ServerId(server));
        try {
          final fetched = await client
              ?.fetchClientSideEpisodeQueue(m['id'] as String)
              .timeout(const Duration(seconds: 25));
          if (!mounted || !current) return;
          if (fetched == null) {
            messages[member.key] = t.fileSources.errorUnavailable;
            return;
          }
          final episodes = context.readFreshWatchStateAll([
            for (final e in fetched)
              e.copyWith(
                serverId: server,
                grandparentId: e.grandparentId ?? m['id'] as String,
                grandparentTitle: e.grandparentTitle ?? m['title'] as String?,
              ),
          ]);
          final turn = rotationEpisodes(episodes);
          eligible[member.key] = turn.episodes;
          if (turn.gap != null) {
            messages[member.key] = '${t.mediaConveniences.missingEpisode} ${turn.gap}';
          } else if (turn.episodes.isEmpty) {
            messages[member.key] = t.fileSources.finished;
          }
        } catch (_) {
          messages[member.key] = t.fileSources.errorUnavailable;
        }
      }

      final members = shows.entries.toList();
      for (var start = 0; start < members.length; start += 4) {
        await Future.wait(members.skip(start).take(4).map(loadMember));
        if (!mounted || !current) return;
      }
      if (!mounted || !current) return;
      setState(() => statuses = messages);
      final previous = [for (final r in sourceList(data['rounds'])) sourceList(r).whereType<String>().toList()];
      final rounds = rotationRounds(eligible, previous, Random());
      if (rounds.isEmpty) return;
      final saved = await sources.repository.updatePreferenceAtomically(
        profile!,
        preference,
        (state) => {
          ...state,
          'rounds': [
            for (final r in rounds) [for (final e in r) e.globalKey],
          ],
        },
      );
      if (!mounted || !current) return;
      setState(() => data = saved);
      final items = rounds.expand((r) => r).toList();
      final queue = context.read<PlaybackStateProvider>();
      queue.setPlaybackFromLocalQueue(
        LocalPlayQueue(items: items, currentIndex: 0),
        contextKey: 'orderedShowRotation:$profile',
      );
      await navigateToVideoPlayer(context, metadata: items.first, resolveWatchState: false);
    } catch (_) {
      if (mounted && current) showErrorSnackBar(context, t.fileSources.errorUnavailable);
    } finally {
      if (mounted && current) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    context.select((SourceController controller) => controller.profileId);
    final show = widget.show, key = show.globalKey;
    return Scaffold(
      appBar: AppBar(title: Text(t.mediaConveniences.showRotation)),
      body: !current
          ? const SizedBox.shrink()
          : ListView(
              children: [
                Padding(padding: const EdgeInsets.all(16), child: Text(t.mediaConveniences.rotationHelp)),
                if (!shows.containsKey(key))
                  ListTile(
                    leading: const Icon(Icons.add),
                    title: Text(show.title ?? key),
                    subtitle: Text(show.serverName ?? ''),
                    onTap: busy ? null : () => _toggle(key),
                  ),
                for (final entry in shows.entries)
                  ListTile(
                    leading: const Icon(Icons.tv),
                    title: Text(sourceMap(entry.value)['title'] as String? ?? entry.key),
                    subtitle: Text(statuses[entry.key] ?? sourceMap(entry.value)['serverName'] as String? ?? ''),
                    trailing: IconButton(
                      tooltip: t.homeLayout.remove,
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: busy ? null : () => _toggle(entry.key),
                    ),
                  ),
                if (busy)
                  const LinearProgressIndicator()
                else if (shows.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton.icon(
                      onPressed: _play,
                      icon: const Icon(Icons.shuffle),
                      label: Text(t.common.play),
                    ),
                  ),
              ],
            ),
    );
  }
}
