import 'package:enlibra_mobile/core/device_tier.dart';
import 'package:enlibra_mobile/ui/add_model_sheet.dart';
import 'package:enlibra_mobile/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _device = DeviceCapabilities(
  totalRamBytes: 8 * 1024 * 1024 * 1024,
  usableRamBytes: 4 * 1024 * 1024 * 1024,
  tier: DeviceTier.capable,
);

/// The padding wrapped directly around the sheet's content column.
EdgeInsets _contentPadding(WidgetTester tester) {
  final padding = tester.widget<Padding>(
    find
        .ancestor(of: find.text('Add a model'), matching: find.byType(Padding))
        .first,
  );
  return padding.padding as EdgeInsets;
}

Future<void> _pump(
  WidgetTester tester, {
  double systemInset = 0,
  double keyboard = 0,
}) {
  return tester.pumpWidget(
    MaterialApp(
      // The sheet reads AppTokens off the theme, so a bare MaterialApp is not
      // enough to build it.
      theme: AppTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          padding: EdgeInsets.only(bottom: systemInset),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        // A real bottom sheet supplies the Material; the TextField needs it.
        child: const Material(child: AddModelSheet(device: _device)),
      ),
    ),
  );
}

void main() {
  group('AddModelSheet insets', () {
    testWidgets('leaves room for the system navigation bar', (tester) async {
      // `showModalBottomSheet(useSafeArea: true)` wraps the sheet in
      // `SafeArea(bottom: false)`, so nothing applies this inset for us and
      // the gesture bar lands on top of the action row.
      await _pump(tester, systemInset: 48);
      expect(_contentPadding(tester).bottom, 24 + 48);
    });

    testWidgets('does not double up when the keyboard is open', (tester) async {
      // A raised keyboard already covers the navigation bar, so the platform
      // reports the system inset as zero. Adding the two is therefore correct
      // rather than double-counting -- but only because exactly one is ever
      // non-zero, which is what this pins.
      await _pump(tester, systemInset: 0, keyboard: 320);
      expect(_contentPadding(tester).bottom, 24);
    });

    testWidgets('sits flush on a device with no inset at all', (tester) async {
      await _pump(tester);
      expect(_contentPadding(tester).bottom, 24);
    });
  });
}
