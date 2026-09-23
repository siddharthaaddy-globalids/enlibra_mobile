import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:enlibra_mobile/models/gguf_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal GGUF writer -- enough header for the probe to have something real to
/// read over HTTP. [padBytes] inflates a metadata string so the header no longer
/// fits in the first request, which is the case worth testing.
Uint8List buildGguf({int padBytes = 0}) {
  final out = BytesBuilder();

  void u32(int v) => out.add(
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List(),
  );
  void u64(int v) => out.add(
    (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List(),
  );
  void str(String s) {
    final bytes = utf8.encode(s);
    u64(bytes.length);
    out.add(bytes);
  }

  void kvString(String k, String v) {
    str(k);
    u32(8);
    str(v);
  }

  void kvU32(String k, int v) {
    str(k);
    u32(4);
    u32(v);
  }

  out.add(ascii.encode('GGUF'));
  u32(3);
  u64(1); // one tensor
  u64(padBytes > 0 ? 8 : 7);
  kvString('general.architecture', 'qwen2');
  kvString('general.name', 'probe fixture');
  kvU32('general.file_type', 15);
  kvU32('qwen2.block_count', 36);
  kvU32('qwen2.attention.head_count', 20);
  kvU32('qwen2.attention.head_count_kv', 4);
  kvU32('qwen2.embedding_length', 2560);
  if (padBytes > 0) {
    // Stands in for `tokenizer.ggml.tokens`, the thing that actually pushes a
    // real header past a couple of megabytes.
    kvString('tokenizer.chat_template', 'x' * padBytes);
  }

  str('token_embd.weight');
  u32(2);
  u64(2560);
  u64(151936);
  u32(15);
  u64(0);

  // Tensor data would follow in a real file. A few bytes stand in for the
  // gigabytes, so `sizeBytes` is provably the whole file and not the header.
  out.add(Uint8List(4096));
  return out.takeBytes();
}

/// Serves [body] with the Range semantics being tested.
class _FakeS3 {
  _FakeS3(
    this.body, {
    this.honourRange = true,
    this.status = 200,
    this.errorBody,
  });

  final Uint8List body;
  final bool honourRange;
  final int status;

  /// What S3 returns alongside a refusal: an XML document naming the cause.
  final String? errorBody;

  HttpServer? _server;
  final requestedRanges = <String?>[];

  Uri get url => Uri.parse('http://127.0.0.1:${_server!.port}/model.gguf');

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      final range = request.headers.value('range');
      requestedRanges.add(range);

      if (status != 200) {
        request.response.statusCode = status;
        if (errorBody != null) {
          request.response.headers.contentType = ContentType(
            'application',
            'xml',
          );
          request.response.write(errorBody);
        }
        await request.response.close();
        return;
      }

      if (range == null || !honourRange) {
        request.response.statusCode = 200;
        request.response.headers.contentLength = body.length;
        request.response.add(body);
        await request.response.close();
        return;
      }

      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final end = match.group(2)!.isEmpty
          ? body.length - 1
          : int.parse(match.group(2)!).clamp(0, body.length - 1);

      request.response.statusCode = 206;
      request.response.headers.set(
        'content-range',
        'bytes $start-$end/${body.length}',
      );
      final slice = Uint8List.sublistView(body, start, end + 1);
      request.response.headers.contentLength = slice.length;
      request.response.add(slice);
      await request.response.close();
    });
  }

  Future<void> stop() => _server!.close(force: true);
}

void main() {
  group('GgufProbe', () {
    test('reads a model header out of a ranged request', () async {
      final server = _FakeS3(buildGguf());
      await server.start();
      addTearDown(server.stop);

      final probe = GgufProbe();
      addTearDown(probe.close);
      final probed = await probe.probe(server.url);

      expect(probed.fileName, 'model.gguf');
      expect(probed.header.architecture, 'qwen2');
      expect(probed.header.layerCount, 36);
      expect(probed.header.kvHeadCount, 4);
      expect(probed.header.headDim, 128);

      // The point of the Content-Range parse: the size is the whole object,
      // not the slice that was fetched.
      expect(probed.sizeBytes, buildGguf().length);
      expect(probed.sizeBytes, greaterThan(probed.header.headerBytes));
      expect(
        server.requestedRanges.single,
        'bytes=0-${GgufProbe.initialBytes - 1}',
      );
    });

    test(
      'widens the request when the header outgrows the first window',
      () async {
        // 3MB of metadata: past the 2MB first ask, so it takes a second trip.
        final server = _FakeS3(buildGguf(padBytes: 3 << 20));
        await server.start();
        addTearDown(server.stop);

        final probe = GgufProbe();
        addTearDown(probe.close);
        final probed = await probe.probe(server.url);

        expect(probed.header.architecture, 'qwen2');
        expect(server.requestedRanges.length, greaterThanOrEqualTo(2));
      },
    );

    test('still works when the server ignores Range entirely', () async {
      final server = _FakeS3(buildGguf(), honourRange: false);
      await server.start();
      addTearDown(server.stop);

      final probe = GgufProbe();
      addTearDown(probe.close);
      final probed = await probe.probe(server.url);

      expect(probed.header.architecture, 'qwen2');
      expect(probed.sizeBytes, buildGguf().length);
    });

    test('blames permissions, not expiry, when S3 says AccessDenied', () async {
      // The failure that actually happens: the link is freshly signed and
      // valid for days, but the identity that signed it may not read the
      // object. Calling that "expired" sends someone off re-signing a URL that
      // was never the problem.
      final server = _FakeS3(
        buildGguf(),
        status: 403,
        errorBody:
            '<?xml version="1.0" encoding="UTF-8"?><Error>'
            '<Code>AccessDenied</Code>'
            '<Message>User: arn:aws:iam::123:user/someone is not authorized '
            'to perform: s3:GetObject</Message>'
            '</Error>',
      );
      await server.start();
      addTearDown(server.stop);

      final probe = GgufProbe();
      addTearDown(probe.close);

      await expectLater(
        probe.probe(server.url),
        throwsA(
          isA<GgufProbeException>()
              .having((e) => e.message, 'message', contains('not allowed'))
              .having((e) => e.message, 'message', contains('s3:GetObject'))
              .having((e) => e.message, 'message', isNot(contains('expired'))),
        ),
      );
    });

    test('reports a genuinely expired signature as expired', () async {
      final server = _FakeS3(
        buildGguf(),
        status: 403,
        errorBody: '<Error><Code>RequestExpired</Code></Error>',
      );
      await server.start();
      addTearDown(server.stop);

      final probe = GgufProbe();
      addTearDown(probe.close);

      await expectLater(
        probe.probe(server.url),
        throwsA(
          isA<GgufProbeException>().having(
            (e) => e.message,
            'message',
            contains('expired'),
          ),
        ),
      );
    });

    test('names a clock skew rather than blaming the link', () async {
      // Plausible on a phone, and nothing about the URL is wrong.
      final server = _FakeS3(
        buildGguf(),
        status: 403,
        errorBody: '<Error><Code>RequestTimeTooSkewed</Code></Error>',
      );
      await server.start();
      addTearDown(server.stop);

      final probe = GgufProbe();
      addTearDown(probe.close);

      await expectLater(
        probe.probe(server.url),
        throwsA(
          isA<GgufProbeException>().having(
            (e) => e.message,
            'message',
            contains('clock'),
          ),
        ),
      );
    });

    test('falls back to the URL stamps when S3 gives no error code', () async {
      final server = _FakeS3(buildGguf(), status: 403);
      await server.start();
      addTearDown(server.stop);

      // Signed a moment ago for a week: expiry is provably not the cause.
      final signed = DateTime.now().toUtc();
      final stamp =
          '${signed.year}'
          '${signed.month.toString().padLeft(2, '0')}'
          '${signed.day.toString().padLeft(2, '0')}T'
          '${signed.hour.toString().padLeft(2, '0')}'
          '${signed.minute.toString().padLeft(2, '0')}'
          '${signed.second.toString().padLeft(2, '0')}Z';
      final url = server.url.replace(
        queryParameters: {'X-Amz-Date': stamp, 'X-Amz-Expires': '604800'},
      );

      final probe = GgufProbe();
      addTearDown(probe.close);

      await expectLater(
        probe.probe(url),
        throwsA(
          isA<GgufProbeException>().having(
            (e) => e.message,
            'message',
            contains('has not expired'),
          ),
        ),
      );
    });

    test('rejects a URL that serves something other than a model', () async {
      final server = _FakeS3(
        Uint8List.fromList(utf8.encode('<?xml version="1.0"?><Error/>')),
      );
      await server.start();
      addTearDown(server.stop);

      final probe = GgufProbe();
      addTearDown(probe.close);

      await expectLater(
        probe.probe(server.url),
        throwsA(isA<GgufProbeException>()),
      );
    });

    test(
      'builds a manifest the rest of the app can size and download',
      () async {
        final server = _FakeS3(buildGguf());
        await server.start();
        addTearDown(server.stop);

        final probe = GgufProbe();
        addTearDown(probe.close);
        final probed = await probe.probe(server.url);

        final manifest = probed.toManifest(
          id: 'fixture',
          displayName: 'Fixture',
        );

        expect(manifest.id, 'fixture');
        expect(manifest.weightsFile.url, server.url.toString());
        expect(manifest.weightsFile.sha256, isNull); // nothing published one
        expect(manifest.quantization, 'Q4_K_M');
        expect(manifest.shape.kvBytesPerToken('q8_0'), greaterThan(0));

        // A 4GB budget must afford some context for a fixture this small, and
        // the estimate must be driven by the file's real size.
        expect(
          manifest.fittableContext(4 * 1024 * 1024 * 1024),
          greaterThan(2048),
        );
        expect(
          manifest.memoryAt(2048).weightsBytes,
          manifest.weightsFile.sizeBytes,
        );
      },
    );
  });
}
