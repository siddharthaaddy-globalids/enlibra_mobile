import 'dart:io';

import 'package:system_info2/system_info2.dart';

/// How much of the device we are actually allowed to use.
enum DeviceTier {
  /// < 4GB RAM. Too small for anything we ship.
  unsupported,

  /// 4-7GB. The 6GB mid-range Android floor. 1B models only.
  baseline,

  /// 8GB+. Can take a 3B at a 4k context.
  capable,
}

class DeviceCapabilities {
  const DeviceCapabilities({
    required this.totalRamBytes,
    required this.usableRamBytes,
    required this.tier,
  });

  final int totalRamBytes;

  /// What we can allocate before the OS kills us. This is the only number
  /// that matters for deciding whether a model can be loaded.
  final int usableRamBytes;

  final DeviceTier tier;

  double get totalRamGb => totalRamBytes / (1024 * 1024 * 1024);
  double get usableRamGb => usableRamBytes / (1024 * 1024 * 1024);

  static DeviceCapabilities detect() {
    final total = _totalPhysicalMemory();
    return DeviceCapabilities(
      totalRamBytes: total,
      usableRamBytes: (total * _usableFraction()).round(),
      tier: _tierFor(total),
    );
  }

  static int _totalPhysicalMemory() {
    try {
      final bytes = SysInfo.getTotalPhysicalMemory();
      if (bytes > 0) return bytes;
    } catch (_) {
      // system_info2 has no implementation on some targets. Fall through.
    }
    // Assume the floor we committed to supporting rather than assuming
    // plenty. A wrong guess downward degrades the model; a wrong guess
    // upward crashes the app.
    return 6 * 1024 * 1024 * 1024;
  }

  /// Fraction of physical RAM a foreground app can hold before the OS
  /// reclaims it.
  ///
  /// iOS jetsam kills an app at roughly 50-55% of device RAM. The
  /// `com.apple.developer.kernel.increased-memory-limit` entitlement raises
  /// this, but it is not granted automatically, so assume the lower bound.
  /// Android is more permissive in the foreground but will kill a large
  /// process the moment it is backgrounded.
  static double _usableFraction() {
    if (Platform.isIOS) return 0.50;
    if (Platform.isAndroid) return 0.55;
    // Desktop is a dev harness. Still cap it, so testing on a 32GB laptop
    // cannot lull us into shipping a configuration a phone will reject.
    return 0.60;
  }

  static DeviceTier _tierFor(int totalBytes) {
    const gb = 1024 * 1024 * 1024;
    if (totalBytes < 4 * gb) return DeviceTier.unsupported;
    if (totalBytes < 8 * gb) return DeviceTier.baseline;
    return DeviceTier.capable;
  }

  @override
  String toString() =>
      'DeviceCapabilities(${totalRamGb.toStringAsFixed(1)}GB total, '
      '${usableRamGb.toStringAsFixed(1)}GB usable, ${tier.name})';
}
