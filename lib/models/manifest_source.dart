import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'model_manifest.dart';

/// Where the app gets its list of available models, and the short-lived URLs
/// to fetch their files.
abstract class ManifestSource {
  /// Models on offer. Safe to cache; contains no URLs.
  Future<List<ModelManifest>> catalog();

  /// Resolves a manifest into one whose files carry presigned URLs.
  ///
  /// Called immediately before a download starts, never cached: presigned
  /// URLs expire, and a resumed download that outlives the expiry must come
  /// back here for a fresh one.
  Future<ModelManifest> resolve(ModelManifest manifest);
}

/// Ships inside the app. Used for the first run before the backend has been
/// reached, and as a fallback when the backend is unreachable.
class BundledManifestSource implements ManifestSource {
  const BundledManifestSource();

  @override
  Future<List<ModelManifest>> catalog() async {
    final raw = await rootBundle.loadString('assets/manifests/catalog.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return (json['models'] as List<dynamic>)
        .map((m) => ModelManifest.fromJson(m as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  Future<ModelManifest> resolve(ModelManifest manifest) {
    throw ManifestException(
      'the bundled catalog carries no download URLs; a backend is required',
    );
  }
}

/// Talks to your API, which holds the AWS credentials and hands back
/// presigned S3 (or CloudFront-signed) URLs.
///
/// Expected endpoints:
///   GET  {baseUrl}/models              -> { "schemaVersion": 1, "models": [...] }
///   POST {baseUrl}/models/{id}/download
///        body: { "version": "2026.09.1" }
///        -> { "urls": { "model-q4_k_m.gguf": "https://...signed..." },
///             "expiresInSeconds": 3600 }
///
/// Nothing here ever sees an AWS key. Anything embedded in the app binary --
/// including --dart-define values -- is extractable, so the signing has to
/// happen server-side.
class BackendManifestSource implements ManifestSource {
  BackendManifestSource({
    required this.baseUrl,
    http.Client? client,
    this.fallback = const BundledManifestSource(),
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final http.Client _client;
  final ManifestSource fallback;
  final Duration timeout;

  @override
  Future<List<ModelManifest>> catalog() async {
    try {
      final res = await _client.get(baseUrl.resolve('models')).timeout(timeout);
      if (res.statusCode != 200) {
        throw ManifestException('catalog returned HTTP ${res.statusCode}');
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      return (json['models'] as List<dynamic>)
          .map((m) => ModelManifest.fromJson(m as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      // Offline, or the backend is down. The bundled catalog still lets the
      // user talk to a model they already downloaded.
      return fallback.catalog();
    }
  }

  @override
  Future<ModelManifest> resolve(ModelManifest manifest) async {
    final res = await _client
        .post(
          baseUrl.resolve('models/${manifest.id}/download'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'version': manifest.version}),
        )
        .timeout(timeout);

    if (res.statusCode != 200) {
      throw ManifestException(
        'could not get download URLs for ${manifest.id}: '
        'HTTP ${res.statusCode}',
      );
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final urls = (json['urls'] as Map<String, dynamic>).cast<String, String>();

    final resolved = manifest.files
        .map((f) {
          final url = urls[f.fileName];
          if (url == null) {
            throw ManifestException(
              'backend did not return a URL for "${f.fileName}"',
            );
          }
          return f.withUrl(url);
        })
        .toList(growable: false);

    return ModelManifest(
      schemaVersion: manifest.schemaVersion,
      id: manifest.id,
      displayName: manifest.displayName,
      version: manifest.version,
      files: resolved,
      quantization: manifest.quantization,
      shape: manifest.shape,
      contextLength: manifest.contextLength,
      chatTemplate: manifest.chatTemplate,
      stopStrings: manifest.stopStrings,
      sampling: manifest.sampling,
      kvCacheType: manifest.kvCacheType,
      description: manifest.description,
    );
  }
}
