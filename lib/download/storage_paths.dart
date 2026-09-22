import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Resolves where model files live on each platform.
///
/// IMPORTANT (iOS/macOS): the directory returned by
/// `getApplicationSupportDirectory()` is backed up to iCloud by default.
/// Apple rejects apps that back up multi-gigabyte re-downloadable data.
/// The exclusion flag cannot be set from Dart -- it needs
/// `URLResourceValues.isExcludedFromBackup` on the native side. See
/// [iosBackupExclusionSnippet] and call it once at startup from
/// AppDelegate.swift.
class StoragePaths {
  StoragePaths._(this.modelsRoot, this.sessionsRoot);

  final Directory modelsRoot;
  final Directory sessionsRoot;

  static StoragePaths? _instance;
  static StoragePaths get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('StoragePaths.init() must be awaited before use');
    }
    return i;
  }

  static Future<StoragePaths> init() async {
    final base = await getApplicationSupportDirectory();
    final models = Directory(p.join(base.path, 'models'));
    final sessions = Directory(p.join(base.path, 'sessions'));
    await models.create(recursive: true);
    await sessions.create(recursive: true);
    return _instance = StoragePaths._(models, sessions);
  }

  /// One directory per model id. Versions replace in place -- we delete the
  /// old version before writing the new one rather than keeping both, since
  /// two copies of a 2GB model will not fit on a 64GB phone.
  Directory modelDir(String modelId) =>
      Directory(p.join(modelsRoot.path, modelId));

  File modelFile(String modelId, String fileName) =>
      File(p.join(modelsRoot.path, modelId, fileName));

  /// Partial download. Promoted to the real name only after the checksum
  /// verifies, so a truncated file can never look like a valid model.
  File partialFile(String modelId, String fileName) =>
      File(p.join(modelsRoot.path, modelId, '$fileName.part'));

  /// Serialised llama.cpp KV cache for a conversation. Lets a reopened chat
  /// skip prompt reprocessing, which is the slowest thing the app does on a
  /// mid-range Android.
  File sessionFile(int conversationId) =>
      File(p.join(sessionsRoot.path, 'conv_$conversationId.state'));

  Future<int> bytesUsed() async {
    var total = 0;
    for (final root in [modelsRoot, sessionsRoot]) {
      if (!await root.exists()) continue;
      await for (final entity in root.list(recursive: true)) {
        if (entity is File) total += await entity.length();
      }
    }
    return total;
  }

  Future<void> deleteModel(String modelId) async {
    final dir = modelDir(modelId);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Paste into ios/Runner/AppDelegate.swift (and the macOS equivalent) and
  /// call it from `application(_:didFinishLaunchingWithOptions:)`.
  static const iosBackupExclusionSnippet = r'''
private func excludeModelsFromBackup() {
  let fm = FileManager.default
  guard let support = fm.urls(for: .applicationSupportDirectory,
                              in: .userDomainMask).first else { return }
  for name in ["models", "sessions"] {
    var url = support.appendingPathComponent(name)
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
  }
}
''';

  static bool get needsBackupExclusion => Platform.isIOS || Platform.isMacOS;
}
