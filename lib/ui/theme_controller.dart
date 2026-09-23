import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the selected theme mode and persists it.
///
/// Defaults to dark. That is a deliberate product choice rather than a
/// system-follow: this is a reading surface people sit in for long
/// stretches, often one-handed in the evening.
class ThemeController extends ChangeNotifier {
  ThemeController._(this._mode, this._prefs);

  static const _key = 'theme_mode';
  static const defaultMode = ThemeMode.dark;

  ThemeMode _mode;
  final SharedPreferences? _prefs;

  ThemeMode get mode => _mode;

  bool get isDark => _mode == ThemeMode.dark;

  static Future<ThemeController> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_key);
      return ThemeController._(_parse(stored) ?? defaultMode, prefs);
    } catch (_) {
      // Preferences are unavailable on some platforms in some states. A
      // theme is not worth failing startup over.
      return ThemeController._(defaultMode, null);
    }
  }

  Future<void> set(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    try {
      await _prefs?.setString(_key, mode.name);
    } catch (_) {
      // Keep the in-memory change; it just will not survive a restart.
    }
  }

  /// Flips between light and dark. If the app is currently following the
  /// system, this pins it to the opposite of whatever is showing now, which
  /// is what a user pressing a toggle expects.
  Future<void> toggle(BuildContext context) {
    final effective = _mode == ThemeMode.system
        ? (MediaQuery.platformBrightnessOf(context) == Brightness.dark
              ? ThemeMode.dark
              : ThemeMode.light)
        : _mode;
    return set(effective == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
  }

  static ThemeMode? _parse(String? value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    'system' => ThemeMode.system,
    _ => null,
  };
}

/// Icon button that flips light/dark, for an app bar.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key, required this.controller});

  final ThemeController controller;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      onPressed: () => controller.toggle(context),
      tooltip: isDark ? 'Switch to light mode' : 'Switch to dark mode',
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        transitionBuilder: (child, animation) => RotationTransition(
          turns: Tween<double>(begin: 0.75, end: 1).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: Icon(
          isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
          key: ValueKey(isDark),
          size: 19,
        ),
      ),
    );
  }
}
