import 'package:flutter/material.dart';

import 'fold_regions.dart';

/// Maps detail pushes from a browse pane to its neighboring navigator. Other
/// routes (especially fullscreen playback) still belong to the profile shell.
class FoldBrowserScope extends InheritedWidget {
  const FoldBrowserScope({super.key, required this.detail, required this.owner, required super.child});
  final NavigatorState? Function()? detail;
  final NavigatorState owner;

  static FoldBrowserScope? of(BuildContext context) => context.getInheritedWidgetOfExactType<FoldBrowserScope>();
  static NavigatorState detailNavigator(BuildContext context) => of(context)?.detail?.call() ?? Navigator.of(context);

  @override
  bool updateShouldNotify(FoldBrowserScope oldWidget) => owner != oldWidget.owner || detail != oldWidget.detail;
}

class FoldBrowser extends StatefulWidget {
  const FoldBrowser({super.key, required this.child});
  final Widget child;
  @override
  State<FoldBrowser> createState() => FoldBrowserState();
}

class FoldBrowserState extends State<FoldBrowser> {
  final _navigator = GlobalKey<NavigatorState>();
  bool _detailOpen = false;

  bool handleBack() {
    final nav = _navigator.currentState;
    if (nav == null || !nav.canPop()) return false;
    nav.maybePop();
    return true;
  }

  void clearDetail() => _navigator.currentState?.popUntil((route) => route.isFirst);

  @override
  Widget build(BuildContext context) => FoldRegionBuilder(
    builder: (context, regions) {
      final panes = regions.usable(width: 260, height: 240);
      final split = panes.length >= 2 && panes.first.top == panes.last.top;
      final owner = Navigator.of(context);
      // A fold can arrive in the very frame in which a detail was pushed,
      // before the navigator has delivered its navigation notification.
      final open = _navigator.currentState?.canPop() ?? _detailOpen;
      return Stack(
        children: [
          regions.place(
            context,
            split ? panes.first : regions.largest,
            ExcludeFocus(
              excluding: open && !split,
              child: ExcludeSemantics(
                excluding: open && !split,
                child: FoldBrowserScope(
                  owner: owner,
                  detail: split ? () => _navigator.currentState : null,
                  child: widget.child,
                ),
              ),
            ),
          ),
          if (split || open)
            regions.place(
              context,
              split ? panes.last : regions.largest,
              FoldBrowserScope(
                owner: owner,
                detail: null,
                child: NotificationListener<NavigationNotification>(
                  onNotification: (_) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      final open = _navigator.currentState?.canPop() ?? false;
                      if (_detailOpen != open) setState(() => _detailOpen = open);
                    });
                    return false;
                  },
                  child: HeroControllerScope.none(
                    child: Navigator(
                      key: _navigator,
                      requestFocus: false,
                      onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const SizedBox.expand()),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
