import 'dart:convert';

import 'model_manifest.dart';

/// Turns whatever the user pasted into a description of where a model's files
/// live.
///
/// Two shapes are accepted, because two things are convenient to paste:
///
///  * a bare `https://` URL to a `.gguf` -- what `scripts/presign-model.mjs`
///    prints, and what fits in a chat message or a clipboard;
///  * the JSON that same script writes with `--manifest`, which additionally
///    carries checksums, a stable id, and more than one file.
///
/// A full [ModelManifest] with URLs on its files is accepted too, so a manifest
/// produced by the backend can be pasted in during development.
class ModelLink {
  const ModelLink({
    required this.files,
    this.id,
    this.displayName,
    this.source,
    this.expiresAt,
    this.manifest,
  });

  final List<ModelLinkFile> files;

  /// Stable identity from the JSON form. Absent for a bare URL, where the id
  /// has to be derived from the URL path instead.
  final String? id;

  final String? displayName;

  /// Where the files came from, for display only (`s3://bucket/prefix/`).
  final String? source;

  /// When the signature dies, as stated by the JSON. [signatureExpiry] reads
  /// the same fact out of the URL itself, which is harder to get wrong.
  final DateTime? expiresAt;

  /// Set when the pasted text was already a complete manifest, in which case
  /// nothing needs probing.
  final ModelManifest? manifest;

  ModelLinkFile get weights =>
      files.firstWhere((f) => f.role == 'weights', orElse: () => files.first);

  /// The soonest expiry among the pasted URLs, or the JSON's own claim.
  DateTime? get earliestExpiry {
    final fromUrls = files
        .map((f) => signatureExpiry(f.url))
        .whereType<DateTime>()
        .toList();
    if (fromUrls.isEmpty) return expiresAt;
    fromUrls.sort();
    return fromUrls.first;
  }

  static ModelLink parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const FormatException('nothing pasted');
    }
    if (text.startsWith('{')) return _fromJson(text);

    // Tolerate a URL that arrived wrapped in quotes or angle brackets, which is
    // what happens when it is copied out of a terminal or a chat client.
    final cleaned = text.replaceAll(RegExp(r'''^["'<]+|["'>]+$'''), '');
    final uri = Uri.tryParse(cleaned);
    if (uri == null || !uri.hasScheme) {
      throw const FormatException(
        'that is neither a URL nor a model JSON file',
      );
    }
    if (uri.scheme == 's3') {
      throw const FormatException(
        'an s3:// address cannot be downloaded directly. Run '
        'scripts/presign-model.mjs on it and paste the https:// URL it prints.',
      );
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw FormatException('unsupported URL scheme "${uri.scheme}"');
    }

    return ModelLink(
      files: [ModelLinkFile(role: 'weights', url: uri)],
    );
  }

  static ModelLink _fromJson(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw FormatException('that JSON does not parse (${e.message})');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('expected a JSON object');
    }

    // A complete manifest: has a shape, so nothing needs to be probed.
    if (decoded.containsKey('shape') && decoded.containsKey('schemaVersion')) {
      final manifest = ModelManifest.fromJson(decoded);
      if (manifest.files.any((f) => f.url == null)) {
        throw const FormatException(
          'that manifest has no download URLs on its files',
        );
      }
      return ModelLink(
        id: manifest.id,
        displayName: manifest.displayName,
        manifest: manifest,
        files: manifest.files
            .map(
              (f) => ModelLinkFile(
                role: f.role,
                url: Uri.parse(f.url!),
                fileName: f.fileName,
                sizeBytes: f.sizeBytes,
                sha256: f.sha256,
              ),
            )
            .toList(growable: false),
      );
    }

    final kind = decoded['kind'] as String?;
    if (kind != null && kind != 'enlibra-model-source') {
      throw FormatException('unrecognised JSON kind "$kind"');
    }

    final rawFiles = decoded['files'];
    if (rawFiles is! List || rawFiles.isEmpty) {
      throw const FormatException('the JSON has no "files" array');
    }

    final files = <ModelLinkFile>[];
    for (final entry in rawFiles) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('every "files" entry must be an object');
      }
      final url = entry['url'] as String?;
      if (url == null) {
        throw FormatException('file "${entry['fileName']}" has no url');
      }
      files.add(
        ModelLinkFile(
          role: entry['role'] as String? ?? 'weights',
          url: Uri.parse(url),
          fileName: entry['fileName'] as String?,
          sizeBytes: entry['sizeBytes'] as int?,
          sha256: (entry['sha256'] as String?)?.toLowerCase(),
        ),
      );
    }

    final expires = decoded['expiresAt'] as String?;
    return ModelLink(
      id: decoded['id'] as String?,
      displayName: decoded['displayName'] as String?,
      source: decoded['source'] as String?,
      expiresAt: expires == null ? null : DateTime.tryParse(expires),
      files: files,
    );
  }

  /// Reads the expiry out of a pre-signed URL's own query string.
  ///
  /// Worth doing before a 2.5GB download rather than after: a SigV4 link is
  /// stamped with the moment it was signed and how long it lasts, so the app
  /// can say "this link dies in 20 minutes" instead of failing at 80%.
  ///
  /// Returns null for a plain URL, and for anything whose stamps do not parse.
  static DateTime? signatureExpiry(Uri url) {
    final q = url.queryParameters;

    final amzDate = q['X-Amz-Date'];
    final amzExpires = int.tryParse(q['X-Amz-Expires'] ?? '');
    if (amzDate != null && amzExpires != null) {
      final signed = _parseAmzDate(amzDate);
      if (signed != null) {
        return signed.add(Duration(seconds: amzExpires));
      }
    }

    // SigV2, and CloudFront signed URLs: an absolute epoch instead.
    final epoch = int.tryParse(q['Expires'] ?? '');
    if (epoch != null) {
      return DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
    }
    return null;
  }

  /// `20260923T215840Z` -- ISO 8601 basic format, which `DateTime.parse` will
  /// not take.
  static DateTime? _parseAmzDate(String value) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$')
        .firstMatch(value);
    if (m == null) return DateTime.tryParse(value);
    return DateTime.utc(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      int.parse(m[4]!),
      int.parse(m[5]!),
      int.parse(m[6]!),
    );
  }

  /// Directory names that say what a thing is rather than which thing it is.
  ///
  /// A run writes `.../<model-run>/quantized/` and `.../<model-run>/gguf/` for
  /// the same model in two formats, so the tail directory never names it --
  /// the run directory does. Kept in step with `GENERIC_SEGMENTS` in
  /// `scripts/presign-model.mjs`, which derives the same id when it writes a
  /// source file; a mismatch would mean the two disagree about whether a
  /// pasted link is an update or a new model.
  static const genericPathSegments = <String>{
    'gguf',
    'quantized',
    'outputs',
    'runs',
    'models',
    'weights',
    'artifacts',
    'export',
  };

  /// A model id derived from a URL, used when the pasted text carries none.
  ///
  /// Built from the S3 key's directory structure rather than the file name,
  /// because every quantisation run produces a file called something like
  /// `model-q4_k_m.gguf` and two different models must not collide on one
  /// on-disk directory. The signature query is ignored, so re-signing the same
  /// object yields the same id -- which is what makes a re-paste update the
  /// model in place instead of installing a second copy.
  static String idFromUrl(Uri url) {
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return 'pasted-model';

    final fileName = segments.removeLast();
    // .../<model-run>/gguf/model.gguf -> <model-run>
    final meaningful = segments.reversed
        .where((s) => !genericPathSegments.contains(s.toLowerCase()))
        .take(1)
        .toList();
    final base = meaningful.isNotEmpty
        ? meaningful.first
        : fileName.replaceAll(RegExp(r'\.gguf$', caseSensitive: false), '');

    final slug = base.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]+'), '-');
    return slug.isEmpty ? 'pasted-model' : slug;
  }
}

class ModelLinkFile {
  const ModelLinkFile({
    required this.role,
    required this.url,
    this.fileName,
    this.sizeBytes,
    this.sha256,
  });

  final String role;
  final Uri url;

  /// From the JSON form. For a bare URL the name comes from the URL path.
  final String? fileName;

  final int? sizeBytes;
  final String? sha256;
}
