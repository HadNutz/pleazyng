import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'src/hole.dart';

/// Displays an LG hardware video plane underneath the controls. The exported
/// window uses logical destination coordinates and full-resolution source pixels.
class WebOSVideoPlane extends StatefulWidget {
  const WebOSVideoPlane({super.key, required this.window, required this.source, required this.onError});
  final String window;
  final Size source;
  final VoidCallback onError;

  static const windows = MethodChannel('webos/exported_windows');

  @override
  State<WebOSVideoPlane> createState() => _WebOSVideoPlaneState();
}

class _WebOSVideoPlaneState extends State<WebOSVideoPlane> {
  Object? _last;
  bool _positioned = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(_layout);
  }

  void _layout(Duration _) {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && !box.size.isEmpty) {
      final offset = box.localToGlobal(Offset.zero);
      if (offset.dx.isFinite && offset.dy.isFinite) {
        final rect = (offset.dx.round(), offset.dy.round(), box.size.width.round(), box.size.height.round());
        final key = (widget.window, widget.source, rect);
        if (_last != key) {
          _last = key;
          WebOSVideoPlane.windows.invokeMethod<void>('resize', {
            'windowId': widget.window,
            'srcRect': [0, 0, widget.source.width.round(), widget.source.height.round()],
            'dstRect': [rect.$1, rect.$2, rect.$3, rect.$4],
          }).then((_) {
            if (mounted && _last == key && !_positioned) setState(() => _positioned = true);
          }, onError: (Object _) {
            if (mounted && _last == key) widget.onError();
          });
        }
      }
    }
    WidgetsBinding.instance.addPostFrameCallback(_layout);
  }

  @override
  Widget build(BuildContext context) => _positioned ? const Hole() : const SizedBox.expand();
}
