import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/strings.g.dart';
import '../services/settings_service.dart';
import 'settings_builder.dart';

final _calibrating = ValueNotifier(false);

/// Four fractions of the full viewport, stored together so a calibration is
/// atomic. Each side may consume up to a quarter of the device's surface.
List<int> projectorInsets(List<String> stored) =>
    List.generate(4, (i) => stored.length == 4 ? (int.tryParse(stored[i]) ?? 0).clamp(0, 250) : 0);

EdgeInsets _padding(List<int> inset, Size size) => EdgeInsets.fromLTRB(
  size.width * inset[0] / 1000,
  size.height * inset[1] / 1000,
  size.width * inset[2] / 1000,
  size.height * inset[3] / 1000,
);

class ProjectorViewport extends StatelessWidget {
  const ProjectorViewport({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (SettingsService.instanceOrNull == null) return child;
    return SettingValueBuilder<List<String>>(
      pref: SettingsService.projectorInsets,
      builder: (context, stored, _) {
        final inset = projectorInsets(stored);

        return ValueListenableBuilder<bool>(
          valueListenable: _calibrating,
          builder: (context, editing, _) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final padding = editing ? EdgeInsets.zero : _padding(inset, constraints.biggest);
                final mq = MediaQuery.of(context);
                BorderSide mask(double width) =>
                    width > 0 ? BorderSide(color: Colors.black, width: width) : BorderSide.none;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      left: mask(padding.left),
                      top: mask(padding.top),
                      right: mask(padding.right),
                      bottom: mask(padding.bottom),
                    ),
                  ),
                  child: Padding(
                    padding: padding,
                    child: ClipRect(
                      child: MediaQuery(
                        data: mq.copyWith(
                          size: padding.deflateSize(constraints.biggest),
                          padding: (mq.padding - padding).clamp(EdgeInsets.zero, mq.padding).resolve(TextDirection.ltr),
                          viewPadding: (mq.viewPadding - padding)
                              .clamp(EdgeInsets.zero, mq.viewPadding)
                              .resolve(TextDirection.ltr),
                          viewInsets: (mq.viewInsets - padding)
                              .clamp(EdgeInsets.zero, mq.viewInsets)
                              .resolve(TextDirection.ltr),
                        ),
                        child: child,
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class ProjectorSetupScreen extends StatefulWidget {
  const ProjectorSetupScreen({super.key});
  @override
  State<ProjectorSetupScreen> createState() => _ProjectorSetupScreenState();
}

class _ProjectorSetupScreenState extends State<ProjectorSetupScreen> {
  late final _insets = projectorInsets(SettingsService.instance.read(SettingsService.projectorInsets));
  int _edge = 0;
  final _adjustFocus = FocusNode();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _calibrating.value = true;
    });
  }

  @override
  void dispose() {
    _adjustFocus.dispose();
    WidgetsBinding.instance.addPostFrameCallback((_) => _calibrating.value = false);
    super.dispose();
  }

  BorderSide _edgeLine(int edge, [double width = 2]) =>
      BorderSide(color: edge == _edge ? Colors.amber : Colors.white, width: width);

  void _adjust(int delta) => setState(() => _insets[_edge] = (_insets[_edge] + delta).clamp(0, 250));
  @override
  Widget build(BuildContext context) {
    final s = t.livingRoom;
    final labels = [s.left, s.top, s.right, s.bottom];
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, box) {
          return Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: _padding(_insets, box.biggest),
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(
                          left: _edgeLine(0),
                          top: _edgeLine(1),
                          right: _edgeLine(2),
                          bottom: _edgeLine(3),
                        ),
                      ),
                      child: Stack(
                        children: [
                          for (final corner in [
                            Alignment.topLeft,
                            Alignment.topRight,
                            Alignment.bottomLeft,
                            Alignment.bottomRight,
                          ])
                            Align(
                              alignment: corner,
                              child: SizedBox(
                                width: 28,
                                height: 28,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border(
                                      left: corner.x < 0 ? _edgeLine(0, 6) : BorderSide.none,
                                      top: corner.y < 0 ? _edgeLine(1, 6) : BorderSide.none,
                                      right: corner.x > 0 ? _edgeLine(2, 6) : BorderSide.none,
                                      bottom: corner.y > 0 ? _edgeLine(3, 6) : BorderSide.none,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Center(
                child: SingleChildScrollView(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(s.fitScreen, style: Theme.of(context).textTheme.titleLarge),
                          Text(s.fitHelp, textAlign: TextAlign.center),
                          Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              for (var i = 0; i < 4; i++)
                                ChoiceChip(
                                  label: Text(labels[i]),
                                  selected: _edge == i,
                                  onSelected: (_) {
                                    setState(() => _edge = i);
                                    _adjustFocus.requestFocus();
                                  },
                                ),
                            ],
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: t.accessibility.decrease,
                                icon: const Icon(Icons.remove),
                                onPressed: () => _adjust(-2),
                              ),
                              Focus(
                                focusNode: _adjustFocus,
                                onKeyEvent: (_, e) {
                                  final key = e.logicalKey;
                                  final horizontal = _edge == 0 || _edge == 2;
                                  final negative = horizontal
                                      ? LogicalKeyboardKey.arrowLeft
                                      : LogicalKeyboardKey.arrowUp;
                                  final positive = horizontal
                                      ? LogicalKeyboardKey.arrowRight
                                      : LogicalKeyboardKey.arrowDown;
                                  if (key != negative && key != positive) return KeyEventResult.ignored;
                                  if (e is! KeyUpEvent) _adjust((key == positive ? 2 : -2) * (_edge >= 2 ? -1 : 1));
                                  return KeyEventResult.handled;
                                },
                                child: Builder(
                                  builder: (context) => DecoratedBox(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Focus.of(context).hasFocus
                                            ? Theme.of(context).colorScheme.primary
                                            : Colors.transparent,
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(6),
                                      child: Text('${labels[_edge]} ${(_insets[_edge] / 10).toStringAsFixed(1)}%'),
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: t.accessibility.increase,
                                icon: const Icon(Icons.add),
                                onPressed: () => _adjust(2),
                              ),
                            ],
                          ),
                          Wrap(
                            children: [
                              TextButton(
                                onPressed: () => setState(() => _insets.fillRange(0, 4, 0)),
                                child: Text(t.common.reset),
                              ),
                              TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
                              FilledButton(
                                onPressed: () async {
                                  await SettingsService.instance.write(
                                    SettingsService.projectorInsets,
                                    _insets.map((v) => v.toString()).toList(),
                                  );
                                  if (context.mounted) Navigator.pop(context);
                                },
                                child: Text(t.common.save),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
