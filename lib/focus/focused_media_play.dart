import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Makes a browse tile's Play operation available to Flutter hardware keys and
/// the Siri Remote bridge. Modal routes and non-media focus have no target.
class FocusedMediaPlay extends InheritedWidget {
  const FocusedMediaPlay({super.key, required this.play, required super.child});
  final bool Function() play;

  static bool fromPrimaryFocus() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null || ModalRoute.isCurrentOf(context) != true) return false;
    return context.getInheritedWidgetOfExactType<FocusedMediaPlay>()?.play() ?? false;
  }

  static KeyEventResult handle(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.mediaPlay && event.logicalKey != LogicalKeyboardKey.mediaPlayPause) {
      return KeyEventResult.ignored;
    }
    return event is KeyDownEvent && fromPrimaryFocus() ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  bool updateShouldNotify(FocusedMediaPlay oldWidget) => false;
}
