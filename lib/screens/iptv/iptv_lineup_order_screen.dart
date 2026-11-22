import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../iptv/iptv_models.dart';
import '../../widgets/app_icon.dart';

class IptvLineupOrderScreen extends StatefulWidget {
  const IptvLineupOrderScreen({super.key, required this.channels});
  final List<IptvEditableChannel> channels;

  @override
  State<IptvLineupOrderScreen> createState() => _IptvLineupOrderScreenState();
}

class _IptvLineupOrderScreenState extends State<IptvLineupOrderScreen> {
  late final _channels = [...widget.channels];

  void _move(int from, int to) => setState(() => _channels.insert(to, _channels.removeAt(from)));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(t.iptv.lineupOrder),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop([for (final channel in _channels) channel.id]),
          child: Text(t.common.save),
        ),
      ],
    ),
    body: SafeArea(
      child: ReorderableListView.builder(
        buildDefaultDragHandles: false,
        itemCount: _channels.length,
        onReorderItem: _move,
        itemBuilder: (context, index) {
          final item = _channels[index];
          return ListTile(
            key: ValueKey(item.id),
            title: Text(item.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: item.displayGroup == null ? null : Text(item.displayGroup!),
            leading: ReorderableDragStartListener(index: index, child: const AppIcon(Symbols.drag_handle_rounded)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: t.iptv.moveUp,
                  onPressed: index == 0 ? null : () => _move(index, index - 1),
                  icon: const AppIcon(Symbols.arrow_upward_rounded),
                ),
                IconButton(
                  tooltip: t.iptv.moveDown,
                  onPressed: index + 1 == _channels.length ? null : () => _move(index, index + 1),
                  icon: const AppIcon(Symbols.arrow_downward_rounded),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}
