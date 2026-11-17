import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/native_primary_view.dart';

class _View {
  const _View(this.id, this.width);

  final int id;
  final double width;
}

void main() {
  test('selects the native primary ID when implicit view zero is empty', () async {
    const implicit = _View(0, 0);
    const primary = _View(1, 800);
    final selected = await waitForNativePrimaryView<_View>(
      readNativeViewId: () async => 1,
      currentViews: () => const [implicit, primary],
      viewId: (view) => view.id,
      isTransientError: (_) => false,
    );

    expect(implicit.width, 0);
    expect(selected, primary);
  });

  test('keeps runApp path synchronous off macOS', () {
    var defaultCalls = 0;
    var resolverCalls = 0;
    var nativeViewCalls = 0;
    runWithOptionalNativeView<int>(
      useNativeView: false,
      runDefault: () => defaultCalls++,
      resolveNativeView: () async {
        resolverCalls++;
        return 1;
      },
      runNativeView: (_) => nativeViewCalls++,
      onFailure: (_, _) => fail('unexpected native-view failure'),
    );

    expect(defaultCalls, 1);
    expect(resolverCalls, 0);
    expect(nativeViewCalls, 0);
  });
}
