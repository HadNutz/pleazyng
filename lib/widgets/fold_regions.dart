import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;
import 'package:flutter/widgets.dart';

/// Panes in a widget's local coordinate system. A fully open continuous screen
/// remains one canvas. A physical gap always separates its two displays.
class FoldRegions {
  FoldRegions(this.viewport, this.features, TextDirection direction) {
    final regions = [Offset.zero & viewport.size];
    for (final feature in features) {
      if (feature.type != DisplayFeatureType.hinge &&
          !(feature.type == DisplayFeatureType.fold && feature.state == DisplayFeatureState.postureHalfOpened)) {
        continue;
      }
      final gap = feature.bounds.shift(-viewport.topLeft);
      final next = <Rect>[];
      for (final r in regions) {
        if (gap.top <= r.top && gap.bottom >= r.bottom && gap.right >= r.left && gap.left <= r.right) {
          next.addAll([
            Rect.fromLTRB(r.left, r.top, gap.left, r.bottom),
            Rect.fromLTRB(gap.right, r.top, r.right, r.bottom),
          ]);
        } else if (gap.left <= r.left && gap.right >= r.right && gap.bottom >= r.top && gap.top <= r.bottom) {
          next.addAll([
            Rect.fromLTRB(r.left, r.top, r.right, gap.top),
            Rect.fromLTRB(r.left, gap.bottom, r.right, r.bottom),
          ]);
        } else {
          next.add(r);
        }
      }
      regions
        ..clear()
        ..addAll(next.where((rect) => !rect.isEmpty));
    }
    regions.sort((a, b) {
      final vertical = a.top.compareTo(b.top);
      if (vertical != 0) return vertical;
      return direction == TextDirection.ltr ? a.left.compareTo(b.left) : b.left.compareTo(a.left);
    });
    panes = List.unmodifiable(regions);
  }

  final Rect viewport;
  final List<DisplayFeature> features;

  EdgeInsets _occlusionInsets(Rect pane, EdgeInsets padding) {
    var left = padding.left, top = padding.top, right = padding.right, bottom = padding.bottom;
    for (final feature in features) {
      if (feature.type != DisplayFeatureType.cutout) continue;
      final bounds = feature.bounds.shift(-viewport.topLeft).intersect(pane);
      if (bounds.isEmpty) continue;
      // Reserve the shortest path between the camera island and a pane edge.
      final distances = [
        bounds.right - pane.left,
        bounds.bottom - pane.top,
        pane.right - bounds.left,
        pane.bottom - bounds.top,
      ];
      final d = distances.reduce(math.min);
      switch (distances.indexOf(d)) {
        case 0:
          left = math.max(left, d);
        case 1:
          top = math.max(top, d);
        case 2:
          right = math.max(right, d);
        case 3:
          bottom = math.max(bottom, d);
      }
    }
    return EdgeInsets.fromLTRB(left, top, right, bottom);
  }

  late final List<Rect> panes;
  Rect get full => Offset.zero & viewport.size;
  bool get divided => panes.length > 1;
  Rect get largest => panes.isEmpty ? Rect.zero : panes.reduce((a, b) => a.size.area >= b.size.area ? a : b);

  /// Use a single viable pane if one side is too small for a second task.
  List<Rect> usable({double width = 160, double height = 100}) =>
      panes.where((p) => p.width >= width && p.height >= height).toList();

  Widget place(BuildContext context, Rect pane, Widget child, {Key? key}) {
    final media = MediaQuery.of(context);
    final global = pane.shift(viewport.topLeft).intersect(Offset.zero & media.size);
    // Keep child identity across posture changes, including the no-hinge path.
    final data = pane == full || global.isEmpty
        ? media
        : media.removeDisplayFeatures(global).copyWith(size: pane.size, displayFeatures: const []);
    return Positioned.fromRect(
      key: key,
      rect: pane,
      child: MediaQuery(
        data: data.copyWith(
          padding: _occlusionInsets(pane, data.padding),
          viewPadding: _occlusionInsets(pane, data.viewPadding),
        ),
        child: child,
      ),
    );
  }
}

extension on Size {
  double get area => width * height;
}

/// Measures the host within the Flutter view, including app bars, safe areas
/// and split-screen offsets. Re-read after layout when a rail or inset moves.
class FoldRegionBuilder extends StatefulWidget {
  const FoldRegionBuilder({super.key, required this.builder});
  final Widget Function(BuildContext, FoldRegions) builder;

  @override
  State<FoldRegionBuilder> createState() => _FoldRegionBuilderState();
}

class _FoldRegionBuilderState extends State<FoldRegionBuilder> {
  Offset _origin = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final features = MediaQuery.displayFeaturesOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (features.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final box = this.context.findRenderObject();
            if (box is! RenderBox || !box.attached || !box.hasSize) return;
            final origin = box.localToGlobal(Offset.zero);
            if (origin.isFinite && origin != _origin) setState(() => _origin = origin);
          });
        }
        return widget.builder(context, FoldRegions(_origin & constraints.biggest, features, direction));
      },
    );
  }
}

/// For single-task views, keep focus, scroll state and platform views alive
/// while only changing the rectangle that contains them.
class FoldPrimaryPane extends StatelessWidget {
  const FoldPrimaryPane({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => FoldRegionBuilder(
    builder: (context, regions) => Stack(children: [regions.place(context, regions.largest, child)]),
  );
}
