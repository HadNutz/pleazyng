import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../iptv/iptv_sports_guide.dart';
import '../../iptv/iptv_source_repository.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../services/base_shared_preferences_service.dart';

class IptvSportsScreen extends StatefulWidget {
  const IptvSportsScreen({super.key, required this.profileId});
  final String profileId;

  @override
  State<IptvSportsScreen> createState() => _IptvSportsScreenState();
}

class _IptvSportsScreenState extends State<IptvSportsScreen> {
  late Future<List<IptvSportsFixture>> _fixtures;
  Set<String> _followed = {};
  bool _favoritesOnly = false;
  bool _writing = false;
  String get _key => profileScopedPrefsKey(widget.profileId, 'iptv_sports_teams');
  bool get _owned => mounted && context.read<ActiveProfileProvider>().activeId == widget.profileId;

  @override
  void initState() {
    super.initState();
    _fixtures = _load();
  }

  Future<List<IptvSportsFixture>> _load() async {
    final repo = context.read<IptvSourceRepository>();
    final now = DateTime.now();
    final prefs = await BaseSharedPreferencesService.sharedCache();
    if (!_owned) return [];
    _followed = (prefs.getStringList(_key) ?? []).toSet();
    final channels = await repo.channels(widget.profileId);
    final programmes = await repo.schedule(widget.profileId, now, now.add(const Duration(days: 3)), matchupsOnly: true);
    return _owned ? IptvSportsFixture.fromGuide(channels, programmes) : [];
  }

  Future<void> _toggle(String team) async {
    if (_writing || !_owned) return;
    setState(() => _writing = true);
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      if (!_owned) return;
      final next = (prefs.getStringList(_key) ?? []).toSet();
      final key = IptvSportsFixture.teamKey(team);
      if (!next.remove(key)) next.add(key);
      await prefs.setStringList(_key, next.toList()..sort());
      if (_owned) setState(() => _followed = next);
    } catch (_) {
      if (mounted && _owned) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.iptv.genericError)));
      }
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = context.watch<ActiveProfileProvider>().activeId;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.videoSettings.motionClaritySports),
        actions: [
          IconButton(
            tooltip: t.liveTv.favorites,
            isSelected: _favoritesOnly,
            selectedIcon: const Icon(Icons.star),
            icon: const Icon(Icons.star_border),
            onPressed: () => setState(() => _favoritesOnly = !_favoritesOnly),
          ),
          IconButton(
            tooltip: t.iptv.refresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _fixtures = _load()),
          ),
        ],
      ),
      body: active != widget.profileId
          ? const SizedBox.shrink()
          : FutureBuilder<List<IptvSportsFixture>>(
              future: _fixtures,
              builder: (context, snapshot) {
                if (snapshot.hasError) return Center(child: Text(t.liveTv.guideReloadFailed));
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final fixtures = (snapshot.data ?? [])
                    .where(
                      (f) =>
                          !_favoritesOnly ||
                          [
                            f.firstTeam,
                            f.secondTeam,
                          ].any((team) => _followed.contains(IptvSportsFixture.teamKey(team))),
                    )
                    .toList();
                if (fixtures.isEmpty) return Center(child: Text(t.liveTv.noPrograms));
                final material = MaterialLocalizations.of(context);
                return ListView.builder(
                  itemCount: fixtures.length,
                  itemBuilder: (context, index) {
                    final fixture = fixtures[index],
                        date = DateTime.fromMillisecondsSinceEpoch(fixture.startsAt * 1000);
                    return ExpansionTile(
                      key: PageStorageKey((
                        fixture.startsAt,
                        fixture.competition,
                        fixture.firstTeam,
                        fixture.secondTeam,
                      )),
                      title: Text('${fixture.firstTeam} · ${fixture.secondTeam}'),
                      subtitle: Text(
                        [
                          if (fixture.competition.isNotEmpty) fixture.competition,
                          material.formatMediumDate(date),
                          material.formatTimeOfDay(
                            TimeOfDay.fromDateTime(date),
                            alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
                          ),
                        ].join(' · '),
                      ),
                      children: [
                        for (final feed in fixture.feeds)
                          ListTile(
                            leading: const Icon(Icons.live_tv),
                            title: Text(feed.channel.displayName),
                            subtitle: Text(feed.channel.liveTvSourceTitle ?? ''),
                            onTap: () => Navigator.of(context).pop(feed),
                          ),
                        for (final team in [fixture.firstTeam, fixture.secondTeam])
                          CheckboxListTile(
                            title: Text('${t.liveTv.favorites} · $team'),
                            value: _followed.contains(IptvSportsFixture.teamKey(team)),
                            onChanged: _writing ? null : (_) => _toggle(team),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
    );
  }
}
