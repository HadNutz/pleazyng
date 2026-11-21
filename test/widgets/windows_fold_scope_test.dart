import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/widgets/windows_fold_scope.dart';
import 'package:plezy/widgets/fold_regions.dart';

void main() {
  const view = Size(800, 600);
  test('spanning two internal panels scales and clips their actual gap', () {
    const panels = [Rect.fromLTRB(-400, -10, 760, 1400), Rect.fromLTRB(780, -10, 1800, 1400)];
    final regions = FoldRegions(Offset.zero & view, windowsPanelFeatures(panels, view, 2, 'auto'), TextDirection.ltr);
    expect(regions.panes, [const Rect.fromLTWH(0, 0, 380, 600), const Rect.fromLTWH(390, 0, 410, 600)]);
  });
  test('an external or ordinary single monitor has no automatic separator', () {
    expect(windowsPanelFeatures([], view, 1, 'vertical'), isEmpty);
    expect(windowsPanelFeatures([Offset.zero & view], view, 1, 'auto'), isEmpty);
  });
  test('manual tabletop follows the physical panel while the window moves', () {
    final folds = windowsPanelFeatures([const Rect.fromLTRB(-200, -400, 1800, 1600)], view, 2, 'horizontal');
    expect(folds.single.bounds, const Rect.fromLTRB(0, 300, 800, 300));
    expect(windowsPanelFeatures([const Rect.fromLTRB(0, -1400, 1600, 1200)], view, 2, 'horizontal'), isEmpty);
  });
}
