import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../services/file_picker_service.dart';
import '../../iptv/iptv_models.dart';
import '../../iptv/iptv_source_repository.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../profiles/profile_activation.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/optimized_media_image.dart';
import 'iptv_lineup_order_screen.dart';

class IptvChannelsSettingsScreen extends StatefulWidget {
  const IptvChannelsSettingsScreen({super.key, required this.profileId, required this.sourceId});

  final String? profileId;
  final String sourceId;

  @override
  State<IptvChannelsSettingsScreen> createState() => _IptvChannelsSettingsScreenState();
}

class _IptvChannelsSettingsScreenState extends State<IptvChannelsSettingsScreen> {
  final _search = TextEditingController();
  List<IptvEditableChannel> _channels = const [];
  Set<String> _lockedGroups = const {};
  bool _loading = true;
  List<IptvLineupGroup> _groups = [];
  String? _selectedGroup;
  String? _providerGroup;
  bool _hideLowBandwidth = false;
  IptvLineupGroup? get _currentGroup => _groups.where((g) => g.id == _selectedGroup).firstOrNull;
  String? _savingChannelId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final profileId = widget.profileId;
    if (profileId == null) {
      setState(() {
        _channels = const [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final repository = context.read<IptvSourceRepository>();
      final channels = await repository.editableChannels(profileId, widget.sourceId);
      final lockedGroups = await repository.lockedGroups(profileId, widget.sourceId);
      final groups = await repository.lineupGroups(profileId, widget.sourceId);
      if (mounted) {
        setState(() {
          _channels = channels;
          _groups = groups;
          if (_currentGroup == null) _selectedGroup = null;
          if (!channels.any((c) => c.displayGroup == _providerGroup)) _providerGroup = null;
          _lockedGroups = lockedGroups;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _loading = false);
        showErrorSnackBar(context, t.iptv.providerUnavailable);
      }
    }
  }

  List<IptvEditableChannel> get _filteredChannels {
    final query = _search.text.trim().toLowerCase();
    final group = _currentGroup;
    return _channels
        .where((c) {
          if (group != null && !group.members.contains(c.id)) return false;
          if (_providerGroup != null && c.displayGroup != _providerGroup) return false;
          if (_hideLowBandwidth && c.groupTitle?.trim().toUpperCase() == 'LOW BANDWIDTH') return false;
          return query.isEmpty ||
              '${c.displayTitle} ${c.displayGroup ?? ''} ${c.number ?? ''} ${c.tvgId ?? ''} ${c.guideIdOverride ?? ''}'
                  .toLowerCase()
                  .contains(query);
        })
        .toList(growable: false);
  }

  Future<void> _editGroup(String action, IptvSourceRepository repository, String profileId) async {
    final selected = {for (final channel in _filteredChannels) channel.id};
    var group = _currentGroup;
    if (action == 'group-add' || action == 'group-remove') {
      group = await showDialog<IptvLineupGroup>(
        context: context,
        builder: (dialog) => SimpleDialog(
          title: Text(t.iptv.channelGroup),
          children: [
            for (final g in _groups) SimpleDialogOption(onPressed: () => Navigator.pop(dialog, g), child: Text(g.name)),
          ],
        ),
      );
      if (group == null || !mounted) return;
      await repository.editLineupGroup(
        profileId,
        widget.sourceId,
        original: group,
        name: group.name,
        add: action == 'group-add' ? selected : const {},
        remove: action == 'group-remove' ? selected : const {},
      );
    } else if (action == 'group-delete') {
      if (group == null) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(t.common.delete),
          content: Text(group!.name),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(t.common.cancel)),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(t.common.delete)),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      await repository.editLineupGroup(profileId, widget.sourceId, original: group, name: group.name, delete: true);
    } else {
      final original = action == 'group-new' ? null : group;
      var name = original?.name ?? '';
      final newName = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(t.iptv.channelGroup),
          content: TextFormField(
            initialValue: name,
            maxLength: 120,
            autofocus: true,
            decoration: InputDecoration(labelText: t.fileSources.name),
            onChanged: (v) => name = v,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog), child: Text(t.common.cancel)),
            FilledButton(onPressed: () => Navigator.pop(dialog, name.trim()), child: Text(t.common.save)),
          ],
        ),
      );
      if (newName == null || newName.isEmpty || !mounted) return;
      await repository.editLineupGroup(profileId, widget.sourceId, original: original, name: newName);
    }
  }

  Future<void> _lineupAction(String action) async {
    final profileId = widget.profileId;
    if (profileId == null || _loading || _savingChannelId != null) return;
    final repository = context.read<IptvSourceRepository>();
    setState(() => _savingChannelId = '');
    try {
      if (action.startsWith('group-')) {
        await _editGroup(action, repository, profileId);
        await _load();
        return;
      }
      if (action == 'm3u' || action == 'xml') {
        final guide = action == 'xml';
        final ids = {for (final channel in _filteredChannels) channel.id};
        if (!guide) {
          final accepted = await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
              title: Text('${t.subtitleAiUi.export} M3U'),
              content: Text(t.iptv.exportPrivate),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(t.common.cancel)),
                FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(t.subtitleAiUi.export)),
              ],
            ),
          );
          if (accepted != true || !mounted) return;
        }
        final contents = await repository.exportLineup(profileId, widget.sourceId, ids, guide: guide);
        if (!mounted) return;
        await FilePickerService.instance.saveFile(
          fileName: guide ? 'pleazyng-guide.xml' : 'pleazyng-channels.m3u',
          bytes: utf8.encode(contents),
        );
        return;
      }
      if (action == 'order') {
        final original = [for (final channel in _channels) channel.id];
        final order = await Navigator.of(
          context,
        ).push<List<String>>(MaterialPageRoute(builder: (_) => IptvLineupOrderScreen(channels: _channels)));
        if (order == null || !mounted) return;
        await repository.saveLineupOrder(profileId, widget.sourceId, original, order);
      } else {
        final hidden = action == 'hide';
        final ids = [
          for (final channel in _filteredChannels)
            if (channel.hidden != hidden) channel.id,
        ];
        if (ids.isEmpty) return;
        final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(hidden ? t.iptv.hideMatches : t.iptv.showMatches),
            content: Text(t.iptv.affectedChannels(count: ids.length)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.common.save)),
            ],
          ),
        );
        if (accepted != true || !mounted) return;
        await repository.setChannelsHidden(profileId, widget.sourceId, ids, hidden, expectedHidden:!hidden);
      }
      await _load();
    } on IptvImportException catch (error) {
      if (mounted) {
        showErrorSnackBar(context, switch (error.code) {
          'source_changed' => t.iptv.orderChanged,
          'dynamic_stream' => t.iptv.dynamicStreamExport,
          _ => t.iptv.sourceInvalid,
        });
      }
      await _load();
    } catch (_) {
      if (mounted) showErrorSnackBar(context, t.iptv.providerUnavailable); // Keep the current lineup on failure.
    } finally {
      if (mounted) setState(() => _savingChannelId = null);
    }
  }

  Future<void> _save(
    IptvEditableChannel channel, {
    required bool hidden,
    required String? title,
    required String? group,
    required String? guideId,
    required bool parentalLocked,
    bool? groupLocked,
    String? groupLockTitle,
  }) async {
    final profileId = widget.profileId;
    if (profileId == null || _savingChannelId != null) return;
    setState(() => _savingChannelId = channel.id);
    try {
      final repository = context.read<IptvSourceRepository>();
      await repository.saveChannelPresentation(
        profileId: profileId,
        sourceId: widget.sourceId,
        channelId: channel.id,
        hidden: hidden,
        customTitle: title,
        groupOverride: group,
        guideIdOverride: guideId,
        parentalLocked: parentalLocked,
      );
      final groupTitle = groupLockTitle?.trim();
      if (groupLocked != null && groupTitle != null && groupTitle.isNotEmpty) {
        await repository.saveGroupLock(
          profileId: profileId,
          sourceId: widget.sourceId,
          groupTitle: groupTitle,
          locked: groupLocked,
        );
      }
      final oldGuideId = channel.guideIdOverride?.trim() ?? '';
      final newGuideId = guideId?.trim() ?? '';
      if (oldGuideId != newGuideId) {
        try {
          await repository.refresh(profileId, widget.sourceId);
        } on Object {
          if (mounted) showErrorSnackBar(context, t.iptv.guideMappingRefreshFailed);
        }
      }
      await _load();
    } catch (error) {
      if (mounted) showErrorSnackBar(context, t.iptv.sourceInvalid);
    } finally {
      if (mounted) setState(() => _savingChannelId = null);
    }
  }

  Future<void> _edit(IptvEditableChannel channel) async {
    final title = TextEditingController(text: channel.customTitle ?? '');
    final group = TextEditingController(text: channel.groupOverride ?? '');
    final guideId = TextEditingController(text: channel.guideIdOverride ?? '');
    var hidden = channel.hidden;
    var parentalLocked = channel.parentalLocked;
    String? effectiveGroupTitle() {
      final custom = group.text.trim();
      final title = custom.isNotEmpty ? custom : channel.groupTitle?.trim();
      return title == null || title.isEmpty ? null : title;
    }

    var groupLocked = _lockedGroups.contains(iptvGroupLockKey(effectiveGroupTitle()));
    final activeProfile = context.read<ActiveProfileProvider>().active;
    final canUseParentalControls =
        activeProfile is LocalProfile && activeProfile.id == widget.profileId && activeProfile.isPinProtected;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(channel.displayTitle),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: InputDecoration(labelText: t.iptv.customChannelName, helperText: t.iptv.useProviderName),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: group,
                  onChanged: (_) => setDialogState(
                    () => groupLocked = _lockedGroups.contains(iptvGroupLockKey(effectiveGroupTitle())),
                  ),
                  decoration: InputDecoration(labelText: t.iptv.customGroupName, helperText: t.iptv.useProviderName),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: guideId,
                  keyboardType: TextInputType.text,
                  textCapitalization: TextCapitalization.none,
                  decoration: InputDecoration(
                    labelText: t.iptv.epgChannelId,
                    hintText: channel.tvgId,
                    helperText: t.iptv.epgChannelIdHelp,
                    prefixIcon: const AppIcon(Symbols.link_rounded),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text(t.iptv.hideFromGuide),
                  value: hidden,
                  onChanged: (value) => setDialogState(() => hidden = value),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  secondary: const AppIcon(Symbols.lock_rounded),
                  title: Text(t.iptv.lockChannel),
                  value: parentalLocked,
                  onChanged: !canUseParentalControls && !parentalLocked
                      ? null
                      : (value) async {
                          if (value && !canUseParentalControls) return;
                          if (canUseParentalControls && !await requestActiveProfileActionPin(context)) {
                            return;
                          }
                          if (!context.mounted) return;
                          setDialogState(() => parentalLocked = value);
                        },
                ),
                if (effectiveGroupTitle() != null)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    secondary: const AppIcon(Symbols.folder_rounded),
                    title: Text(t.iptv.lockChannelGroup),
                    subtitle: Text(effectiveGroupTitle()!),
                    value: groupLocked,
                    onChanged: !canUseParentalControls && !groupLocked
                        ? null
                        : (value) async {
                            if (value && !canUseParentalControls) return;
                            if (canUseParentalControls && !await requestActiveProfileActionPin(context)) {
                              return;
                            }
                            if (!context.mounted) return;
                            setDialogState(() => groupLocked = value);
                          },
                  ),
                if (!canUseParentalControls)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(t.iptv.parentalPinRequired, style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(t.common.cancel)),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(t.common.save)),
          ],
        ),
      ),
    );
    if (saved == true && mounted) {
      await _save(
        channel,
        hidden: hidden,
        title: title.text,
        group: group.text,
        guideId: guideId.text,
        parentalLocked: parentalLocked,
        groupLocked: effectiveGroupTitle() == null ? null : groupLocked,
        groupLockTitle: effectiveGroupTitle(),
      );
    }
    title.dispose();
    group.dispose();
    guideId.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final channels = _filteredChannels;
    return FocusedScrollScaffold(
      title: Text(t.iptv.manageChannels),
      actions: [
        PopupMenuButton<String>(
          enabled: !_loading && _savingChannelId == null && _channels.isNotEmpty,
          onSelected: _lineupAction,
          itemBuilder: (_) => [
            PopupMenuItem(value: 'group-new', child: Text('${t.profiles.add} · ${t.iptv.channelGroup}')),
            if (_groups.isNotEmpty) ...[
              PopupMenuItem(
                value: 'group-add',
                child: Text('${t.profiles.add} · ${t.liveTv.channelsSection} → ${t.iptv.channelGroup}'),
              ),
              PopupMenuItem(
                value: 'group-remove',
                child: Text('${t.watchTogether.remove} · ${t.liveTv.channelsSection}'),
              ),
            ],
            if (_currentGroup != null) ...[
              PopupMenuItem(value: 'group-rename', child: Text('${t.iptv.edit} · ${_currentGroup!.name}')),
              PopupMenuItem(value: 'group-delete', child: Text('${t.common.delete} · ${_currentGroup!.name}')),
            ],
            PopupMenuItem(value: 'order', child: Text(t.iptv.lineupOrder)),
            PopupMenuItem(value: 'show', child: Text(t.iptv.showMatches)),
            PopupMenuItem(value: 'hide', child: Text(t.iptv.hideMatches)),
            PopupMenuItem(value: 'm3u', child: Text('${t.subtitleAiUi.export} M3U')),
            PopupMenuItem(value: 'xml', child: Text('${t.subtitleAiUi.export} XMLTV')),
          ],
        ),
        IconButton(
          tooltip: t.iptv.refresh,
          onPressed: _loading || _savingChannelId != null ? null : _load,
          icon: const AppIcon(Symbols.refresh_rounded, fill: 1),
        ),
      ],
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          sliver: SliverToBoxAdapter(
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: t.iptv.searchChannels,
                prefixIcon: const AppIcon(Symbols.search_rounded),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: t.common.clear,
                        onPressed: () {
                          _search.clear();
                          setState(() {});
                        },
                        icon: const AppIcon(Symbols.close_rounded),
                      ),
              ),
            ),
          ),
        ),
        if (_channels.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  PopupMenuButton<String>(
                    tooltip: t.iptv.channelGroup,
                    onSelected: (value) => setState(() {
                      _providerGroup = value.startsWith('provider:') ? value.substring(9) : null;
                      _selectedGroup = value.startsWith('saved:') ? value.substring(6) : null;
                    }),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'all', child: Text(t.libraries.all)),
                      for (final g in _groups) PopupMenuItem(value: 'saved:${g.id}', child: Text(g.name)),
                      if (_groups.isNotEmpty) const PopupMenuDivider(),
                      for (final name
                          in (_channels.map((c) => c.displayGroup).whereType<String>().toSet().toList()..sort()))
                        PopupMenuItem(value: 'provider:$name', child: Text(name)),
                    ],
                    child: Chip(
                      label: Text(_currentGroup?.name ?? _providerGroup ?? t.iptv.channelGroup),
                      avatar: const Icon(Icons.filter_list),
                    ),
                  ),
                  if (_channels.any((c) => c.groupTitle?.trim().toUpperCase() == 'LOW BANDWIDTH'))
                    FilterChip(
                      label: Text('${t.metadataEdit.hide} · LOW BANDWIDTH'),
                      selected: _hideLowBandwidth,
                      onSelected: (v) => setState(() => _hideLowBandwidth = v),
                    ),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(t.iptv.pickerCredit, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        if (_loading)
          const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()))
        else if (_channels.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(t.iptv.noChannels, textAlign: TextAlign.center),
              ),
            ),
          )
        else if (channels.isEmpty)
          SliverFillRemaining(hasScrollBody: false, child: Center(child: Text(t.search.tryDifferentTerm)))
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final channel = channels[index];
                final trailing = index + 1 < channels.length ? tokens(context).groupGap : 0.0;
                return Padding(
                  padding: EdgeInsets.only(bottom: trailing),
                  child: Material(
                    color: tokens(context).surface,
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(borderRadius: groupItemRadii(context, index, channels.length)),
                    child: ListTileTheme.merge(
                      visualDensity: PlatformDetector.isAutomotive()
                          ? VisualDensity.standard
                          : const VisualDensity(vertical: -3),
                      child: ListTile(
                        title: Row(
                          children: [
                            Expanded(child: Text(channel.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
                            if (channel.parentalLocked ||
                                _lockedGroups.contains(iptvGroupLockKey(channel.displayGroup)))
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: AppIcon(Symbols.lock_rounded, size: 16, color: colors.onSurfaceVariant),
                              ),
                          ],
                        ),
                        leading: SizedBox(
                          width: 40,
                          height: 40,
                          child: channel.logoUrl == null
                              ? Center(child: AppIcon(Symbols.live_tv_rounded, fill: 1, color: colors.onSurfaceVariant))
                              : OptimizedMediaImage.thumb(
                                  imagePath: channel.logoUrl,
                                  width: 40,
                                  height: 40,
                                  fit: BoxFit.contain,
                                  fallbackIcon: Symbols.live_tv_rounded,
                                ),
                        ),
                        subtitle: Text(
                          [
                            if (channel.number != null) channel.number!,
                            if (channel.displayGroup != null) channel.displayGroup!,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: _savingChannelId == null ? () => _edit(channel) : null,
                        trailing: Switch.adaptive(
                          value: !channel.hidden,
                          onChanged: _savingChannelId == channel.id
                              ? null
                              : (visible) => _save(
                                  channel,
                                  hidden: !visible,
                                  title: channel.customTitle,
                                  group: channel.groupOverride,
                                  guideId: channel.guideIdOverride,
                                  parentalLocked: channel.parentalLocked,
                                ),
                        ),
                      ),
                    ),
                  ),
                );
              }, childCount: channels.length),
            ),
          ),
      ],
    );
  }
}
