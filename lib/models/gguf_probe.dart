import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/memory_math.dart';
import 'gguf_header.dart';
import 'model_link.dart';
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

  /// Whether the file carries the chat template inside it.
  ///
  /// Worth checking before the download rather than after: the bridge asks
  /// llama.cpp for the model's own template and **fails the request** when
  /// there is none, rather than guessing a format and producing subtly wrong
  /// output (`lb_format_prompt` in llama_bridge.cpp). So a GGUF converted
  /// without its template downloads fine, loads fine, and then cannot hold a
  /// conversation -- which is a miserable thing to discover after 2.3GB.
  ///
  /// A `chat_template.jinja` sitting beside the GGUF in the bucket is a hint
  /// that it was *not* embedded: converters pick the template up from
  /// `tokenizer_config.json`, and a standalone jinja file is the newer
  /// Transformers convention that older ones do not read.
  bool get hasChatTemplate =>
      header.chatTemplate != null && header.chatTemplate!.isNotEmpty;

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

    if (response.statusCode != 200 && response.statusCode != 206) {
      await _failFromResponse(response, url);
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

  /// Turns a refusal into something that names the actual cause.
  ///
  /// A pre-signed URL can fail for several unrelated reasons that all arrive as
  /// HTTP 403, and guessing between them wastes a lot of somebody's afternoon:
  /// the signature really did expire, or the identity that signed it may not
  /// read the object, or it was signed for the wrong region, or the device
  /// clock is off, or the URL lost characters on the way through a chat client.
  ///
  /// S3 says which in the response body, so read it rather than guess.
  static Future<Never> _failFromResponse(
    http.StreamedResponse response,
    Uri url,
  ) async {
    final body = await _readErrorBody(response.stream);
    final code = _xmlTag(body, 'Code');
    final detail = _xmlTag(body, 'Message');

    String explain(String text) =>
        detail == null ? text : '$text\n\nS3 said: $detail';

    switch (code) {
      case 'AccessDenied':
        return throw GgufProbeException(
          explain(
            'S3 refused this link. The link itself is fine -- the AWS identity '
            'that signed it is not allowed to read that object. Check which '
            'credentials were exported when the URL was generated.',
          ),
        );
      case 'ExpiredToken':
      case 'TokenRefreshRequired':
        return throw GgufProbeException(
          explain(
            'The credentials that signed this link have expired. They were '
            'temporary (an STS session), so the link died with them however '
            'long it was signed for. Sign a new one.',
          ),
        );
      case 'RequestExpired':
      case 'AccessDenied.RequestExpired':
        return throw GgufProbeException(
          'This link has expired. Generate a fresh one and paste it again -- '
          'a part-finished download will resume rather than restart.',
        );
      case 'SignatureDoesNotMatch':
        return throw GgufProbeException(
          explain(
            'The signature on this link is not valid for this object. It was '
            'most likely signed for a different region, or with a mismatched '
            'secret key.',
          ),
        );
      case 'InvalidAccessKeyId':
        return throw GgufProbeException(
          explain(
            'AWS does not recognise the access key that signed this link.',
          ),
        );
      case 'RequestTimeTooSkewed':
        return throw GgufProbeException(
          'This device\'s clock is too far from the real time for AWS to '
          'accept the signature. Fix the date and time, then try again.',
        );
      case 'AuthorizationQueryParametersError':
      case 'InvalidRequest':
        return throw GgufProbeException(
          explain(
            'This link is malformed -- most often it was truncated on the way '
            'here. Copy the whole URL, including everything after the "?".',
          ),
        );
      case 'NoSuchKey':
        return throw GgufProbeException(
          'There is no object at that path. Check the file name in the bucket.',
        );
      case 'NoSuchBucket':
        return throw GgufProbeException('That bucket does not exist.');
    }

    if (response.statusCode == 404) {
      return throw GgufProbeException('Nothing at that URL (HTTP 404).');
    }

    if (response.statusCode == 403) {
      // No machine-readable code came back. The URL's own stamps still settle
      // the expiry question, so at least do not blame something provably
      // untrue.
      final expiry = ModelLink.signatureExpiry(url);
      if (expiry != null && expiry.isAfter(DateTime.now().toUtc())) {
        return throw GgufProbeException(
          'The server refused this link (HTTP 403), but it has not expired -- '
          'it is signed until ${expiry.toIso8601String()}. That points at the '
          'signing credentials not being allowed to read the object.',
        );
      }
      if (expiry != null) {
        return throw GgufProbeException(
          'This link expired at ${expiry.toIso8601String()}. Generate a fresh '
          'one -- a part-finished download will resume rather than restart.',
        );
      }
      return throw GgufProbeException(
        explain(
          'The server refused this link (HTTP 403). Either it has expired or '
          'the credentials that signed it cannot read the object.',
        ),
      );
    }

    return throw GgufProbeException(
      explain('The server answered HTTP ${response.statusCode}.'),
    );
  }

  /// Error documents are small; anything past this is not one, and there is no
  /// reason to pull a gigabyte of body to quote in a message.
  static Future<String> _readErrorBody(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in stream) {
        builder.add(chunk);
        if (builder.length >= 8192) break;
      }
    } catch (_) {
      // A body we cannot read just means a less specific message.
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  static String? _xmlTag(String body, String tag) {
    final match = RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(body);
    final value = match?.group(1)?.trim();
    return (value == null || value.isEmpty) ? null : value;
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
