import '../core/memory_math.dart';

class ManifestException implements Exception {
  ManifestException(this.message);
  final String message;
  @override
  String toString() => 'ManifestException: $message';
}

/// One downloadable file belonging to a model.
class ModelFile {
  const ModelFile({
    required this.role,
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
    this.url,
  });

  /// 'weights' | 'projector' | 'adapter'
  final String role;

  /// Name to store it under on disk. Never taken from the URL, which is
  /// presigned and carries query parameters.
  final String fileName;

  final int sizeBytes;

  /// Null when the file's checksum is not known ahead of time -- a model added
  /// by pasting a pre-signed URL has no catalog entry to carry one. The
  /// downloader then falls back to checking the byte count, which catches a
  /// truncated transfer but not a corrupted one. Anything served from the
  /// catalog must carry a real checksum.
  final String? sha256;

  /// Presigned, short-lived. Null in the bundled manifest; filled in by the
  /// backend at request time.
  final String? url;

  ModelFile withUrl(String value) => ModelFile(
    role: role,
    fileName: fileName,
    sizeBytes: sizeBytes,
    sha256: sha256,
    url: value,
  );

  factory ModelFile.fromJson(Map<String, dynamic> json) {
    final sha = json['sha256'] as String?;
    if (sha != null && sha.length != 64) {
      throw ManifestException(
        'file "${json['fileName']}" has a malformed sha256',
      );
    }
    return ModelFile(
      role: json['role'] as String? ?? 'weights',
      fileName: json['fileName'] as String,
      sizeBytes: json['sizeBytes'] as int,
      sha256: sha?.toLowerCase(),
      url: json['url'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'role': role,
    'fileName': fileName,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
    'url': url,
  };
}

class SamplingDefaults {
  const SamplingDefaults({
    this.temperature = 0.7,
    this.topP = 0.95,
    this.topK = 40,
    this.repeatPenalty = 1.1,
    this.maxTokens = 512,
  });

  final double temperature;
  final double topP;
  final int topK;
  final double repeatPenalty;

  /// Capped deliberately. On a mid-range Android at ~6 tok/s an unbounded
  /// generation is a two-minute battery drain the user cannot predict.
  final int maxTokens;

  factory SamplingDefaults.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const SamplingDefaults();
    return SamplingDefaults(
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
      topP: (json['topP'] as num?)?.toDouble() ?? 0.95,
      topK: json['topK'] as int? ?? 40,
      repeatPenalty: (json['repeatPenalty'] as num?)?.toDouble() ?? 1.1,
      maxTokens: json['maxTokens'] as int? ?? 512,
    );
  }

  Map<String, dynamic> toJson() => {
    'temperature': temperature,
    'topP': topP,
    'topK': topK,
    'repeatPenalty': repeatPenalty,
    'maxTokens': maxTokens,
  };
}

/// Schema v1. Bump [schemaVersion] on any breaking change and keep the
/// parser able to read older versions -- shipped apps will hold old
/// manifests in cache long after the backend has moved on.
class ModelManifest {
  const ModelManifest({
    required this.schemaVersion,
    required this.id,
    required this.displayName,
    required this.version,
    required this.files,
    required this.quantization,
    required this.shape,
    required this.contextLength,
    required this.chatTemplate,
    required this.stopStrings,
    required this.sampling,
    this.kvCacheType = 'q8_0',
    this.description,
  });

  static const supportedSchemaVersion = 1;

  final int schemaVersion;

  /// Stable across versions. Used as the on-disk directory name.
  final String id;

  final String displayName;

  /// Changing this triggers a re-download. Use a date or semver, not a hash.
  final String version;

  final List<ModelFile> files;
  final String quantization;
  final ModelShape shape;

  /// Context the model was trained/validated for. The runtime may load it
  /// with less if the device cannot afford the KV cache.
  final int contextLength;

  /// Override for the template baked into the GGUF. Prefer the GGUF's own
  /// template; set this only when it is missing or wrong.
  final String? chatTemplate;

  final List<String> stopStrings;
  final SamplingDefaults sampling;
  final String kvCacheType;
  final String? description;

  ModelFile get weightsFile => files.firstWhere(
    (f) => f.role == 'weights',
    orElse: () => throw ManifestException('manifest "$id" has no weights file'),
  );

  int get totalDownloadBytes => files.fold(0, (sum, f) => sum + f.sizeBytes);

  /// Peak memory at a given context. Pass the context you intend to load
  /// with, not necessarily [contextLength].
  ///
  /// The weights term comes from the file's own size rather than from
  /// parameter count times bits-per-weight. The manifest already states the
  /// exact byte count, so there is no reason to estimate what is known.
  MemoryEstimate memoryAt(int context) => estimateMemory(
    shape: shape,
    quantization: quantization,
    contextLength: context,
    kvType: kvCacheType,
    weightsBytesOverride: weightsFile.sizeBytes,
  );

  /// Largest context this device can afford, clamped to what the model
  /// supports. Zero means the model does not fit at all.
  int fittableContext(int usableRamBytes) {
    final maxFit = maxContextForBudget(
      shape: shape,
      quantization: quantization,
      budgetBytes: usableRamBytes,
      kvType: kvCacheType,
      weightsBytesOverride: weightsFile.sizeBytes,
    );
    return maxFit < contextLength ? maxFit : contextLength;
  }

  /// A model is only offered if it fits with meaningful context left over.
  /// A 512-token window is technically "fitting" and practically useless.
  bool fitsOn(int usableRamBytes) => fittableContext(usableRamBytes) >= 2048;

  factory ModelManifest.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'] as int?;
    if (version == null) {
      throw ManifestException('missing schemaVersion');
    }
    if (version > supportedSchemaVersion) {
      throw ManifestException(
        'manifest schema v$version is newer than this app supports '
        '(v$supportedSchemaVersion). Update the app.',
      );
    }

    final shapeJson = json['shape'] as Map<String, dynamic>?;
    if (shapeJson == null) {
      throw ManifestException('missing "shape" -- required to size memory');
    }

    final filesJson = json['files'] as List<dynamic>?;
    if (filesJson == null || filesJson.isEmpty) {
      throw ManifestException('missing "files"');
    }

    return ModelManifest(
      schemaVersion: version,
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      version: json['version'] as String,
      files: filesJson
          .map((f) => ModelFile.fromJson(f as Map<String, dynamic>))
          .toList(growable: false),
      quantization: json['quantization'] as String? ?? 'Q4_K_M',
      shape: ModelShape(
        paramCount: shapeJson['paramCount'] as int,
        layerCount: shapeJson['layerCount'] as int,
        kvHeadCount: shapeJson['kvHeadCount'] as int,
        headDim: shapeJson['headDim'] as int,
      ),
      contextLength: json['contextLength'] as int? ?? 4096,
      chatTemplate: json['chatTemplate'] as String?,
      stopStrings:
          (json['stopStrings'] as List<dynamic>?)?.cast<String>().toList(
            growable: false,
          ) ??
          const [],
      sampling: SamplingDefaults.fromJson(
        json['defaults'] as Map<String, dynamic>?,
      ),
      kvCacheType: json['kvCacheType'] as String? ?? 'q8_0',
      description: json['description'] as String?,
    );
  }

  /// Round-trips through [fromJson]. Used to persist a manually added model,
  /// which has no catalog to be re-read from.
  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'displayName': displayName,
    'description': description,
    'version': version,
    'quantization': quantization,
    'kvCacheType': kvCacheType,
    'contextLength': contextLength,
    'chatTemplate': chatTemplate,
    'stopStrings': stopStrings,
    'shape': {
      'paramCount': shape.paramCount,
      'layerCount': shape.layerCount,
      'kvHeadCount': shape.kvHeadCount,
      'headDim': shape.headDim,
    },
    'files': files.map((f) => f.toJson()).toList(growable: false),
    'defaults': sampling.toJson(),
  };

  ModelManifest withFiles(List<ModelFile> replacement) => ModelManifest(
    schemaVersion: schemaVersion,
    id: id,
    displayName: displayName,
    version: version,
    files: replacement,
    quantization: quantization,
    shape: shape,
    contextLength: contextLength,
    chatTemplate: chatTemplate,
    stopStrings: stopStrings,
    sampling: sampling,
    kvCacheType: kvCacheType,
    description: description,
  );
}
