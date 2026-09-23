import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manifest_source.dart';
import 'model_link.dart';
import 'model_manifest.dart';

/// Models the user added by pasting a link, held on the device.
///
/// These exist because the catalog endpoint sits behind Cognito and the app
/// does not log in yet. A manifest here was built by probing the GGUF itself,
/// so it is as complete as one from the backend -- with one difference: it
/// carries its download URL, which the backend's never does. That URL is a
/// pre-signed, expiring capability to read one object. It is stored because
/// there is nothing to re-request it from; when it expires the user pastes a
/// fresh one and the model updates in place.
class ManualModelStore extends ChangeNotifier {
  ManualModelStore._(this._prefs, this._models);

  static const _prefsKey = 'manual_models_v1';

  final SharedPreferences _prefs;
  final List<ModelManifest> _models;

  List<ModelManifest> get models => List.unmodifiable(_models);

  bool contains(String id) => _models.any((m) => m.id == id);

  ModelManifest? byId(String id) => _models.cast<ModelManifest?>().firstWhere(
    (m) => m!.id == id,
    orElse: () => null,
  );

  static Future<ManualModelStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? const [];

    final models = <ModelManifest>[];
    for (final entry in raw) {
      try {
        models.add(
          ModelManifest.fromJson(jsonDecode(entry) as Map<String, dynamic>),
        );
      } catch (e) {
        // A stored manifest this build can no longer read is dropped rather
        // than crashing the app on launch. The files it points at stay on disk
        // and become unreferenced, which `StoragePaths.bytesUsed` still counts.
        debugPrint('manual model dropped (unreadable): $e');
      }
    }
    return ManualModelStore._(prefs, models);
  }

  /// Adds [manifest], replacing any existing model with the same id.
  ///
  /// Replacing in place is the point: re-pasting a refreshed URL for a model
  /// already on disk must not mean a second 2.5GB download.
  Future<void> upsert(ModelManifest manifest) async {
    final index = _models.indexWhere((m) => m.id == manifest.id);
    if (index >= 0) {
      _models[index] = manifest;
    } else {
      _models.add(manifest);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _models.removeWhere((m) => m.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() => _prefs.setStringList(
    _prefsKey,
    _models.map((m) => jsonEncode(m.toJson())).toList(growable: false),
  );
}

/// Serves the manually added models. [resolve] hands back the stored URL,
/// having first checked that it has not expired.
class ManualModelSource implements ManifestSource {
  ManualModelSource(this.store);

  final ManualModelStore store;

  @override
  Future<List<ModelManifest>> catalog() async => store.models;

  @override
  Future<ModelManifest> resolve(ModelManifest manifest) async {
    final stored = store.byId(manifest.id) ?? manifest;

    for (final file in stored.files) {
      final url = file.url;
      if (url == null) {
        throw ManifestException(
          '"${stored.displayName}" has no download link. Add it again with a '
          'fresh pre-signed URL.',
        );
      }
      final expiry = ModelLink.signatureExpiry(Uri.parse(url));
      if (expiry != null && expiry.isBefore(DateTime.now().toUtc())) {
        throw ManifestException(
          'the download link for "${stored.displayName}" expired '
          '${_ago(expiry)}. Run scripts/presign-model.mjs again and paste the '
          'new URL -- the model will resume, not restart.',
        );
      }
    }
    return stored;
  }

  static String _ago(DateTime when) {
    final delta = DateTime.now().toUtc().difference(when);
    if (delta.inDays >= 1) return '${delta.inDays}d ago';
    if (delta.inHours >= 1) return '${delta.inHours}h ago';
    return '${delta.inMinutes}m ago';
  }
}

/// Presents the pasted-in models alongside whatever the backend offers.
///
/// Manual models come first: they are the ones that can actually be
/// downloaded right now, and burying them under catalog entries that need a
/// login the app does not have would be the wrong order.
class CompositeManifestSource implements ManifestSource {
  CompositeManifestSource({required this.manual, required this.remote});

  final ManualModelSource manual;
  final ManifestSource remote;

  @override
  Future<List<ModelManifest>> catalog() async {
    final mine = await manual.catalog();
    List<ModelManifest> theirs;
    try {
      theirs = await remote.catalog();
    } catch (e) {
      debugPrint('remote catalog unavailable: $e');
      theirs = const [];
    }
    // A manual entry wins over a catalog entry with the same id: the pasted
    // link is the newer, more specific statement about that model.
    final ids = mine.map((m) => m.id).toSet();
    return [...mine, ...theirs.where((m) => !ids.contains(m.id))];
  }

  @override
  Future<ModelManifest> resolve(ModelManifest manifest) =>
      manual.store.contains(manifest.id)
      ? manual.resolve(manifest)
      : remote.resolve(manifest);
}
