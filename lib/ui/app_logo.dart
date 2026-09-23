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
