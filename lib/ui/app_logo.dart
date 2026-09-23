import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The Enlibra wordmark, picking the artwork that suits the current theme.
///
/// The two SVGs are not recolourings of one another: the dark-background
/// version uses a softer orange (#f69446) than the light one (#f67711),
/// which is the usual correction for a saturated hue glowing against a dark
/// field. So this swaps whole assets rather than tinting one.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.height = 24, this.semanticLabel = 'Enlibra'});

  final double height;
  final String semanticLabel;

  /// Source artwork is 866x273.
  static const aspectRatio = 866 / 273;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asset = isDark
        ? 'assets/logo/enlibra-dark.svg'
        : 'assets/logo/enlibra-light.svg';

    return SvgPicture.asset(
      asset,
      height: height,
      // Width is given explicitly so the widget has an intrinsic size before
      // the SVG finishes parsing; without it the app bar jumps on first
      // frame.
      width: height * aspectRatio,
      fit: BoxFit.contain,
      semanticsLabel: semanticLabel,
      placeholderBuilder: (_) =>
          SizedBox(height: height, width: height * aspectRatio),
    );
  }
}

/// The mark on its own, without the wordmark beside it.
///
/// Same artwork the launcher icons are generated from
/// (`scripts/make-icons.mjs`), so what the user tapped on the home screen is
/// what greets them inside. Single-colour and theme-independent: the orange
/// carries on both backgrounds, which is why there is one file here and two
/// of the wordmark.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.height = 48, this.semanticLabel = 'Enlibra'});

  final double height;
  final String semanticLabel;

  /// Source artwork is 149x190.
  static const aspectRatio = 149 / 190;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/logo/enlibra-mark.svg',
      height: height,
      width: height * aspectRatio,
      fit: BoxFit.contain,
      semanticsLabel: semanticLabel,
      placeholderBuilder: (_) =>
          SizedBox(height: height, width: height * aspectRatio),
    );
  }
}
