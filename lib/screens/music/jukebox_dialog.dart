import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../i18n/strings.g.dart';
import '../../karaoke/karaoke_room_server.dart';
import '../../media/ids.dart';
import '../../media/media_library.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/libraries_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/music/guest_jukebox.dart';

Future<void> showGuestJukebox(BuildContext context) async {
  final room = context.read<GuestJukebox>();
  final hidden = context.read<HiddenLibrariesProvider>();
  await hidden.ensureInitialized();
  if (!context.mounted) return;
  final servers = context.read<MultiServerProvider>();
  final libraries = context
      .read<LibrariesProvider>()
      .libraries
      .where(
        (lib) =>
            lib.kind.isMusic &&
            !lib.hidden &&
            lib.serverId != null &&
            servers.isServerOnline(ServerId(lib.serverId!)) &&
            !hidden.hiddenLibraryKeys.contains(lib.globalKey),
      )
      .toList();
  final networks = await KaraokeRoomServer.addresses().catchError((Object _) => <String>[]);
  if (!context.mounted) return;
  var network = networks.firstOrNull;
  MediaLibrary? selected = libraries.firstOrNull;
  bool busy = false;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (context, setState) => ListenableBuilder(
        listenable: room,
        builder: (context, _) {
          final s = t.livingRoom;
          final link = room.link;
          return AlertDialog(
            title: Text(s.jukebox),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: link == null
                    ? [
                        Text(s.jukeboxInfo),
                        if (libraries.isNotEmpty)
                          DropdownButton<MediaLibrary>(
                            value: selected,
                            isExpanded: true,
                            hint: Text(s.chooseLibrary),
                            items: [
                              for (final lib in libraries)
                                DropdownMenuItem(value: lib, child: Text([lib.title, ?lib.serverName].join(' · '))),
                            ],
                            onChanged: busy ? null : (value) => setState(() => selected = value),
                          )
                        else
                          Text(s.roomUnavailable),
                        if (networks.length > 1)
                          DropdownButton<String>(
                            value: network,
                            isExpanded: true,
                            items: [
                              for (final address in networks) DropdownMenuItem(value: address, child: Text(address)),
                            ],
                            onChanged: busy ? null : (value) => setState(() => network = value),
                          ),
                        if (networks.isEmpty) Text(s.noNetwork),
                        if (error != null) Text(error!),
                      ]
                    : [
                        Text(s.join),
                        Text(room.library!.title),
                        QrImageView(data: link.toString(), size: 200, backgroundColor: Colors.white),
                        SelectableText(link.toString()),
                      ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialog), child: Text(t.common.close)),
              if (link == null)
                FilledButton(
                  onPressed: selected == null || network == null || busy
                      ? null
                      : () async {
                          setState(() {
                            busy = true;
                            error = null;
                          });
                          try {
                            await room.open(selected!, address: network);
                          } catch (_) {
                            error = s.noNetwork;
                          } finally {
                            if (context.mounted) setState(() => busy = false);
                          }
                        },
                  child: Text(s.openRoom),
                )
              else
                FilledButton(onPressed: room.close, child: Text(s.closeRoom)),
            ],
          );
        },
      ),
    ),
  );
}
