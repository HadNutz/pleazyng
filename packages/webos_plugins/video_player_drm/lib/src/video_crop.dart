import 'package:flutter/widgets.dart';

/// Fraction of the decoded frame displayed by the LG exported window.
class VideoCrop extends InheritedWidget {
  const VideoCrop({required this.source, required super.child, super.key});

  final Rect source;

  static Rect of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VideoCrop>()?.source ?? const Rect.fromLTWH(0, 0, 1, 1);

  /// Endpoints are rounded separately to keep the crop inside the decoder's frame.
  static List<int> pixels(Rect crop, Size size) {
    final width = size.width.round(), height = size.height.round();
    final left = (crop.left * width).round().clamp(0, width - 1);
    final top = (crop.top * height).round().clamp(0, height - 1);
    final right = (crop.right * width).round().clamp(left + 1, width);
    final bottom = (crop.bottom * height).round().clamp(top + 1, height);
    return [left, top, right - left, bottom - top];
  }

  @override
  bool updateShouldNotify(VideoCrop oldWidget) => source != oldWidget.source;
}
