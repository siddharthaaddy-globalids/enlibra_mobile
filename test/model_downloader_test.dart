import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:enlibra_mobile/core/memory_math.dart';
import 'package:enlibra_mobile/download/model_downloader.dart';
import 'package:enlibra_mobile/download/storage_paths.dart';
import 'package:enlibra_mobile/models/manifest_source.dart';
import 'package:enlibra_mobile/models/model_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

ModelManifest _manifest(String url, {required int sizeBytes}) => ModelManifest(
  schemaVersion: 1,
  id: 'test-model',
  displayName: 'Test Model',
  version: '1',
  files: [
    ModelFile(
      role: 'weights',
      fileName: 'model.gguf',
      sizeBytes: sizeBytes,
      sha256: null,
      url: url,
    ),
  ],
  quantization: 'Q4_K_M',
  shape: const ModelShape(
    paramCount: 1000000,
    layerCount: 16,
    kvHeadCount: 4,
    headDim: 64,
  ),
  contextLength: 4096,
  chatTemplate: null,
  stopStrings: const [],
  sampling: const SamplingDefaults(),
);

/// Hands back the manifest it was given; the URL is already on the files.
class _StaticSource implements ManifestSource {
  @override
  Future<List<ModelManifest>> catalog() async => const [];
  @override
  Future<ModelManifest> resolve(ModelManifest manifest) async => manifest;
}

/// Sends [preamble] bytes, then goes quiet without closing the connection --
/// the shape of a real stall, which produces no error and no end of stream.
///
/// The preamble is deliberately large: dart:io's HttpClient buffers a small
/// body and delivers nothing until more arrives, so a few kilobytes would
/// exercise the buffering rather than the download.
class _StallingServer {
  /// Large enough to get past dart:io's buffering, small enough to stay quick.
  static const preamble = 512 * 1024;

  /// What the response claims, so the download never completes on its own.
  static const totalSize = 4 << 20;

  HttpServer? _server;

  Uri get url => Uri.parse('http://127.0.0.1:${_server!.port}/model.gguf');

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      request.response.statusCode = 200;
      request.response.headers.contentLength = totalSize;
      request.response.add(Uint8List(preamble));
      await request.response.flush();
      // Deliberately never closed.
    });
  }

  Future<void> stop() => _server!.close(force: true);
}

void main() {
  late Directory root;
  late StoragePaths paths;

  setUp(() {
    root = Directory.systemTemp.createTempSync('enlibra_dl_test');
    paths = StoragePaths.at(root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('a stalled connection', () {
    test('fails instead of hanging at a fixed percentage', () async {
      final server = _StallingServer();
      await server.start();
      addTearDown(server.stop);

      final downloader = ModelDownloader(
        source: _StaticSource(),
        paths: paths,
        stallTimeout: const Duration(milliseconds: 400),
      );

      final progress = await downloader
          .download(_manifest(server.url.toString(), sizeBytes: 4 << 20))
          .toList();

      expect(progress.last.stage, DownloadStage.failed);
      expect(progress.last.error, isA<DownloadStalled>());
      expect('${progress.last.error}', contains('Tap Download to resume'));
    });

    test('keeps what arrived, so the retry is a resume', () async {
      final server = _StallingServer();
      await server.start();
      addTearDown(server.stop);

      final downloader = ModelDownloader(
        source: _StaticSource(),
        paths: paths,
        stallTimeout: const Duration(milliseconds: 400),
      );
      final manifest = _manifest(server.url.toString(), sizeBytes: 4 << 20);

      await downloader.download(manifest).drain<void>();

      // Discarding the partial would turn every stall into a restart, which on
      // a 2.3GB file is the difference between an annoyance and a disaster.
      final partial = paths.partialFile('test-model', 'model.gguf');
      expect(partial.existsSync(), isTrue);
      expect(partial.lengthSync(), greaterThanOrEqualTo(256 * 1024));
      expect(partial.lengthSync(), lessThanOrEqualTo(512 * 1024));
      expect(
        await downloader.bytesOnDisk(manifest),
        greaterThanOrEqualTo(256 * 1024),
      );
    });
  });

  group('cancel', () {
    test('takes effect while the connection is stalled', () async {
      // The bug this pins: cancellation used to be a flag read when the next
      // chunk arrived, so on a stalled connection -- exactly when a user
      // reaches for Cancel -- nothing happened until the stall timed out.
      final server = _StallingServer();
      await server.start();
      addTearDown(server.stop);

      final downloader = ModelDownloader(
        source: _StaticSource(),
        paths: paths,
        stallTimeout: const Duration(seconds: 30),
      );

      final stages = <DownloadStage>[];
      final done = Completer<void>();
      final sub = downloader
          .download(_manifest(server.url.toString(), sizeBytes: 4 << 20))
          .listen((p) => stages.add(p.stage), onDone: done.complete);
      addTearDown(sub.cancel);

      // Let the request get as far as the stall, then cancel.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      downloader.cancel();

      await done.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('cancel did not end the download'),
      );
      expect(stages.last, DownloadStage.cancelled);
    });
  });

  group('deleteFiles', () {
    test(
      'clears a partial download but leaves the model addressable',
      () async {
        final server = _StallingServer();
        await server.start();
        addTearDown(server.stop);

        final downloader = ModelDownloader(
          source: _StaticSource(),
          paths: paths,
          stallTimeout: const Duration(milliseconds: 400),
        );
        final manifest = _manifest(server.url.toString(), sizeBytes: 4 << 20);

        await downloader.download(manifest).drain<void>();
        expect(await downloader.bytesOnDisk(manifest), greaterThan(0));

        await downloader.deleteFiles(manifest);

        expect(await downloader.bytesOnDisk(manifest), 0);
        expect(await downloader.isInstalled(manifest), isFalse);
        expect(paths.modelDir('test-model').existsSync(), isFalse);
      },
    );

    test('leaves nothing behind, including the version marker', () async {
      // The complaint this pins: after removing a model and re-pasting the
      // same link, the download appeared to pick up where the deleted one
      // left off. Anything surviving here would do exactly that, because the
      // model id is derived from the URL and so comes back identical.
      final manifest = _manifest(
        'http://example.invalid/m.gguf',
        sizeBytes: 1024,
      );
      final dir = paths.modelDir('test-model')..createSync(recursive: true);
      File('${dir.path}/model.gguf').writeAsBytesSync(List.filled(1024, 0));
      File('${dir.path}/model.gguf.part').writeAsBytesSync(List.filled(99, 0));
      File('${dir.path}/.version').writeAsStringSync('1');

      final downloader = ModelDownloader(source: _StaticSource(), paths: paths);
      expect(await downloader.isInstalled(manifest), isTrue);

      await downloader.deleteFiles(manifest);

      expect(dir.existsSync(), isFalse);
      expect(await downloader.bytesOnDisk(manifest), 0);
      expect(await downloader.isInstalled(manifest), isFalse);
      // The models root itself survives -- other models live there.
      expect(paths.modelsRoot.existsSync(), isTrue);
    });

    test('reports zero for a model that was never downloaded', () async {
      final downloader = ModelDownloader(source: _StaticSource(), paths: paths);
      expect(
        await downloader.bytesOnDisk(
          _manifest('http://example.invalid/m.gguf', sizeBytes: 10),
        ),
        0,
      );
    });
  });
}
