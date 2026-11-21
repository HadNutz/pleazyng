import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../i18n/strings.g.dart';
import '../../utils/external_url.dart';

class IptvPickerCredit extends StatelessWidget {
  const IptvPickerCredit({super.key});

  static final _project = Uri.https('github.com', '/zschmook/m3u-web-picker');

  Future<void> _openProject(BuildContext context) async {
    if (!isTvosRunner && await openExternalUrl(_project)) return;
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('M3U Web Picker'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Zachary Schmook (@zschmook)'),
              const SizedBox(height: 12),
              SizedBox.square(
                dimension: 164,
                child: QrImageView(data: _project.toString(), size: 164, backgroundColor: Colors.white),
              ),
              const SizedBox(height: 12),
              SelectableText(_project.toString()),
            ],
          ),
        ),
        actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(dialog), child: Text(t.common.close))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => _openProject(context),
    child: Text(t.iptv.pickerCredit, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
  );
}
