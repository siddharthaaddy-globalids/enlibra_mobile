import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/memory_math.dart';
import 'gguf_header.dart';
import 'model_manifest.dart';

/// What a probe of a remote GGUF found: enough to build a manifest, read out
/// of the first few megabytes of a multi-gigabyte file.
class ProbedGguf {
  const ProbedGguf({
    required this.url,
    required this.fileName,
    required this.sizeBytes,
    required this.header,
  });

  final Uri url;

  /// Taken from the URL path, never from a header, and stripped of query
  /// parameters -- a pre-signed URL's query is a signature, not a name.
  final String fileName;

  final int sizeBytes;
  final GgufHeader header;

  /// Builds the manifest the rest of the app already knows how to consume.
  ///
  /// [id] is supplied by the caller rather than derived here, because it
  /// decides whether a re-pasted URL replaces an existing install or sits
  /// beside it as a second 2.5GB copy.
  ModelManifest toManifest({
    required String id,
    required String displayName,
    String? version,
    String? sha256,
    String? description,
  }) {
    return ModelManifest(
      schemaVersion: ModelManifest.supportedSchemaVersion,
      id: id,
      displayName: displayName,
      // Content-addressed enough for the purpose: the version marker exists to
      // notice that the bytes on disk are stale, and size changes whenever the
      // model is requantised or rebuilt.
      version: version ?? 'probed-$sizeBytes',
      files: [
        ModelFile(
          role: 'weights',
          fileName: fileName,
          sizeBytes: sizeBytes,
          sha256: sha256,
          url: url.toString(),
        ),
      ],
      quantization: header.quantization ?? 'Q4_K_M',
      shape: header.shape,
      contextLength: header.contextLength,
      // Left null deliberately: llama.cpp reads the template baked into the
      // GGUF, and this file has one more often than not.
      chatTemplate: null,
      stopStrings: defaultStopStrings,
      sampling: const SamplingDefaults(),
      description: description,
    );
  }

  /// The end-of-turn markers used by the chat templates in circulation. The
  /// real stop is the GGUF's EOS token, which llama.cpp handles itself; these
  /// only catch a model that emits the marker as text instead.
  static const defaultStopStrings = <String>[
    '<|im_end|>',
    '<|eot_id|>',
    '<|end_of_text|>',
    '<end_of_turn>',
  ];
}

class GgufProbeException implements Exception {
  GgufProbeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Fetches just enough of a remote GGUF to read its header.
///
/// Uses ranged GETs rather than HEAD: a pre-signed S3 URL signs the method as
/// well as the path, so a HEAD against a URL signed for GET fails the
/// signature check. The total file size comes from the `Content-Range` of the
/// first ranged response instead.
class GgufProbe {
  GgufProbe({http.Client? client, this.timeout = const Duration(seconds: 30)})
    : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  /// First ask. Large enough that a model with a modest vocabulary parses in
  /// one round trip, small enough to be quick on a phone connection.
  static const initialBytes = 2 << 20;

  /// Ceiling on the prefetch. A header past this is either pathological or a
  /// file that is not what it claims to be; either way, stop pulling.
  static const maxHeaderBytes = 64 << 20;

  Future<ProbedGguf> probe(Uri url) async {
    var want = initialBytes;
    Uint8List? buffer;
    int? totalSize;

    while (true) {
      final fetched = await _fetchPrefix(url, want);
      buffer = fetched.bytes;
      totalSize ??= fetched.totalSize;

      if (buffer.length < want && buffer.length < (totalSize ?? want)) {
        throw GgufProbeException(
          'the server returned ${buffer.length} bytes of the $want requested',
        );
      }

      try {
        final header = GgufHeader.parse(buffer);
        return ProbedGguf(
          url: url,
          fileName: _fileNameFrom(url),
          sizeBytes: totalSize ?? buffer.length,
          header: header,
        );
      } on GgufNeedsMoreBytes catch (e) {
        // The whole file is already in hand and it still does not parse, so
        // more bytes will not help.
        if (totalSize != null && buffer.length >= totalSize) {
          throw GgufProbeException('the file ends inside its own header');
        }
        if (e.atLeast > maxHeaderBytes) {
          throw GgufProbeException(
            'this file wants ${e.atLeast ~/ (1 << 20)}MB of header, which is '
            'past what the app will prefetch',
          );
        }
        want = e.atLeast;
      } on GgufFormatException catch (e) {
        throw GgufProbeException(e.message);
      }
    }
  }

  Future<({Uint8List bytes, int? totalSize})> _fetchPrefix(
    Uri url,
    int want,
  ) async {
    final request = http.Request('GET', url)
      ..headers['Range'] = 'bytes=0-${want - 1}';

    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw GgufProbeException('the server did not respond within $timeout');
    }

    if (response.statusCode == 403) {
      throw GgufProbeException(
        'the URL was refused (HTTP 403). Pre-signed links expire -- generate '
        'a fresh one and paste it again.',
      );
    }
    if (response.statusCode == 404) {
      throw GgufProbeException('nothing at that URL (HTTP 404)');
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw GgufProbeException(
        'the server answered HTTP ${response.statusCode}',
      );
    }

    // 206 carries `Content-Range: bytes 0-N/TOTAL`, which is the only place the
    // full size appears. A 200 means the range was ignored and the body is the
    // entire file, so Content-Length is the size -- and the read below has to
    // stop early rather than pull gigabytes.
    final totalSize = response.statusCode == 206
        ? _totalFromContentRange(response.headers['content-range'])
        : response.contentLength;

    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      builder.add(chunk);
      if (builder.length >= want) break; // cancels the subscription
    }

    final bytes = builder.takeBytes();
    return (
      bytes: bytes.length > want
          ? Uint8List.sublistView(bytes, 0, want)
          : bytes,
      totalSize: totalSize,
    );
  }

  static int? _totalFromContentRange(String? value) {
    if (value == null) return null;
    final slash = value.lastIndexOf('/');
    if (slash < 0) return null;
    return int.tryParse(value.substring(slash + 1).trim());
  }

  /// `https://host/a/b/model-q4_k_m.gguf?X-Amz-Signature=...` -> the file name.
  /// Falls back to a generic name for URLs that route the object through a
  /// query parameter instead of the path.
  static String _fileNameFrom(Uri url) {
    for (final segment in url.pathSegments.reversed) {
      if (segment.isNotEmpty) return Uri.decodeComponent(segment);
    }
    return 'model.gguf';
  }

  void close() => _client.close();
}

extension on GgufHeader {
  /// The subset of the header that memory estimation needs.
  ModelShape get shape => ModelShape(
    paramCount: paramCount,
    layerCount: layerCount,
    kvHeadCount: kvHeadCount,
    headDim: headDim,
  );
}
