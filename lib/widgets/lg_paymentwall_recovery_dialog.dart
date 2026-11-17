import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../services/supporter/lg_paymentwall_client.dart';
import '../services/supporter/supporter_service.dart';
import 'app_icon.dart';

@immutable
class LgRecoverySubmission {
  const LgRecoverySubmission(this.code, {required this.confirmSwitch});

  final String code;
  final bool confirmSwitch;
}

/// Reveals the accountless recovery code and requires an explicit save
/// acknowledgement before the caller may open checkout.
Future<bool> ensureLGRecoveryCodeSaved(BuildContext context, SupporterService service) async {
  final offer = await service.prepareLGRecoveryCode();
  if (!context.mounted || offer == null) return false;
  if (offer.acknowledged) return true;
  final saved = await showLGRecoveryCodeDisclosure(context, offer.code, requireAcknowledgement: true);
  if (!context.mounted || saved != true) return false;
  return service.acknowledgeLGRecoveryCode();
}

/// Lets the viewer reveal or resave their current recovery code from Settings.
Future<void> showLGRecoveryCode(BuildContext context, SupporterService service) async {
  final offer = await service.prepareLGRecoveryCode();
  if (!context.mounted || offer == null) return;
  final saved = await showLGRecoveryCodeDisclosure(context, offer.code, requireAcknowledgement: !offer.acknowledged);
  if (!context.mounted || saved != true || offer.acknowledged) return;
  await service.acknowledgeLGRecoveryCode();
}

Future<bool?> showLGRecoveryCodeDisclosure(BuildContext context, String code, {required bool requireAcknowledgement}) =>
    showDialog<bool>(
      context: context,
      barrierDismissible: !requireAcknowledgement,
      builder: (context) => _RecoveryCodeDisclosureDialog(code: code, requireAcknowledgement: requireAcknowledgement),
    );

/// Prompts for a checksum-valid code before any credential reaches the server.
Future<LgRecoverySubmission?> showLGRecoveryCodeImportDialog(
  BuildContext context, {
  required bool hasExistingIdentity,
}) {
  final controller = TextEditingController();
  var codeValid = false;
  var switchConfirmed = !hasExistingIdentity;
  return showDialog<LgRecoverySubmission>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(t.appAccess.lgRecoveryImportTitle),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.appAccess.lgRecoveryImportInstructions),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                maxLines: 2,
                maxLength: 90,
                textCapitalization: TextCapitalization.none,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: t.appAccess.lgRecoveryCodeLabel,
                  errorText: controller.text.isEmpty || codeValid ? null : t.appAccess.lgRecoveryCodeInvalid,
                ),
                onChanged: (value) => setState(() => codeValid = LgPaymentwallClient.parseRecoveryCode(value) != null),
              ),
              if (hasExistingIdentity) ...[
                const SizedBox(height: 8),
                Text(t.appAccess.lgRecoverySwitchWarning),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: switchConfirmed,
                  onChanged: (value) => setState(() => switchConfirmed = value ?? false),
                  title: Text(t.appAccess.lgRecoveryConfirmSwitch),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.cancel)),
          FilledButton(
            onPressed: codeValid && switchConfirmed
                ? () => Navigator.of(
                    context,
                  ).pop(LgRecoverySubmission(controller.text.trim(), confirmSwitch: switchConfirmed))
                : null,
            child: Text(t.appAccess.lgRecoveryRestore),
          ),
        ],
      ),
    ),
  ).whenComplete(controller.dispose);
}

Future<bool> restoreLGWithRecoveryCodePrompt(BuildContext context, SupporterService service) async {
  final submission = await showLGRecoveryCodeImportDialog(
    context,
    hasExistingIdentity: service.hasLGPaymentwallIdentity,
  );
  if (!context.mounted || submission == null) return false;
  return service.restoreLGWithRecoveryCode(submission.code, confirmSwitch: submission.confirmSwitch);
}

class _RecoveryCodeDisclosureDialog extends StatefulWidget {
  const _RecoveryCodeDisclosureDialog({required this.code, required this.requireAcknowledgement});

  final String code;
  final bool requireAcknowledgement;

  @override
  State<_RecoveryCodeDisclosureDialog> createState() => _RecoveryCodeDisclosureDialogState();
}

class _RecoveryCodeDisclosureDialogState extends State<_RecoveryCodeDisclosureDialog> {
  bool _saved = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.appAccess.lgRecoveryTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.appAccess.lgRecoveryInstructions),
            const SizedBox(height: 8),
            Text(t.appAccess.lgRecoveryWarning),
            const SizedBox(height: 16),
            SelectableText(
              _groupCode(widget.code),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontFamily: 'monospace'),
              textAlign: TextAlign.center,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: widget.code)),
                icon: const AppIcon(Symbols.content_copy_rounded, fill: 1),
                label: Text(t.appAccess.lgRecoveryCopy),
              ),
            ),
            if (widget.requireAcknowledgement)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _saved,
                onChanged: (value) => setState(() => _saved = value ?? false),
                title: Text(t.appAccess.lgRecoverySaved),
                controlAffinity: ListTileControlAffinity.leading,
              ),
          ],
        ),
      ),
      actions: [
        if (widget.requireAcknowledgement)
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.common.cancel))
        else
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.common.close)),
        if (widget.requireAcknowledgement)
          FilledButton(
            onPressed: _saved ? () => Navigator.of(context).pop(true) : null,
            child: Text(t.appAccess.lgRecoveryContinue),
          ),
      ],
    );
  }

  String _groupCode(String value) {
    if (!value.startsWith('LGR1:')) return value;
    final payload = value.substring(5);
    final groups = <String>[];
    for (var index = 0; index < payload.length; index += 5) {
      groups.add(payload.substring(index, (index + 5).clamp(0, payload.length)));
    }
    return 'LGR1:\n${groups.join(' ')}';
  }
}
