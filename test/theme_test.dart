import 'package:enlibra_mobile/ui/app_logo.dart';
import 'package:enlibra_mobile/ui/theme.dart';
import 'package:enlibra_mobile/ui/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget wrap(Widget child, {required Brightness brightness}) {
  return MaterialApp(
    theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
    home: Scaffold(body: child),
  );
}

void main() {
  group('theme mode', () {
    test('defaults to dark', () {
      expect(ThemeController.defaultMode, ThemeMode.dark);
    });
  });

  group('tokens', () {
    testWidgets('are available on both themes', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        late AppTokens tokens;
        await tester.pumpWidget(
          wrap(
            Builder(
              builder: (context) {
                tokens = context.tokens;
                return const SizedBox();
              },
            ),
            brightness: brightness,
          ),
        );
        // Reading tokens must never throw: every widget colour goes
        // through this extension, so a missing registration would be a
        // null-assertion crash on first paint rather than a subtle
        // styling bug.
        expect(tokens.background, isNotNull);
        expect(tokens.accent, isNotNull);
      }
    });

    test('light and dark register different token sets', () {
      final light = AppTheme.light().extension<AppTokens>()!;
      final dark = AppTheme.dark().extension<AppTokens>()!;
      expect(light.background, isNot(dark.background));
      expect(light.text, isNot(dark.text));
      // The scaffold colour must track the token, or the page background
      // and the surfaces painted on it come from different palettes.
      expect(AppTheme.dark().scaffoldBackgroundColor, dark.background);
      expect(AppTheme.light().scaffoldBackgroundColor, light.background);
    });

    test('accent follows the logo artwork, which differs per mode', () {
      // The dark-theme logo uses a softer orange than the light one. If
      // these ever converge, a button will sit next to the wordmark in a
      // visibly different colour.
      expect(AppTokens.light.accent, AppColors.accentLight);
      expect(AppTokens.dark.accent, AppColors.accentDark);
      expect(AppTokens.light.accent, isNot(AppTokens.dark.accent));
    });

    test('dark background is warm charcoal, not pure black', () {
      final bg = AppTokens.dark.background;
      expect(bg, isNot(const Color(0xFF000000)));
      // Warm means red channel above blue.
      expect((bg.r * 255).round(), greaterThan((bg.b * 255).round()));
    });
  });

  group('AppLogo', () {
    testWidgets('renders in both themes', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await tester.pumpWidget(
          wrap(const AppLogo(height: 24), brightness: brightness),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AppLogo), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('reserves its width before the SVG parses', (tester) async {
      // Without an explicit width the app bar reflows on first frame.
      await tester.pumpWidget(
        wrap(const AppLogo(height: 20), brightness: Brightness.dark),
      );
      final size = tester.getSize(find.byType(AppLogo));
      expect(size.height, 20);
      expect(size.width, closeTo(20 * AppLogo.aspectRatio, 0.5));
    });
  });
}
