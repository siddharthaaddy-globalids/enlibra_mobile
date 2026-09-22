import 'dart:async';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/manifest_source.dart';
import '../models/model_manifest.dart';
import 'storage_paths.dart';

enum DownloadStage {
  resolving,
  downloading,
  verifying,
  done,
  failed,
  cancelled,
}

class DownloadProgress {
  const DownloadProgress({
    required this.stage,
    required this.receivedBytes,
    required this.totalBytes,
    this.bytesPerSecond = 0,
    this.error,
  });

  final DownloadStage stage;
  final int receivedBytes;
  final int totalBytes;
  final double bytesPerSecond;
  final Object? error;

  double get fraction =>
      totalBytes == 0 ? 0 : (receivedBytes / totalBytes).clamp(0.0, 1.0);

  Duration? get eta {
    if (bytesPerSecond <= 0 || stage != DownloadStage.downloading) return null;
    final remaining = totalBytes - receivedBytes;
    return Duration(seconds: (remaining / bytesPerSecond).round());
  }
}

class DownloadCancelled implements Exception {}

class ChecksumMismatch implements Exception {
  ChecksumMismatch(this.fileName, this.expected, this.actual);
  final String fileName, expected, actual;
  @override
  String toString() =>
      'ChecksumMismatch($fileName: expected $expected, got $actual)';
}

/// Downloads model files with resume, integrity verification, and atomic
/// promotion.
///
/// A 2GB download over mobile will be interrupted. Every design choice here
/// assumes that: partial files persist across app launches, HTTP Range picks
/// up where it left off, and nothing is treated as a usable model until its
/// SHA-256 matches.
class ModelDownloader {
  ModelDownloader({
    required this.source,
    http.Client? client,
    StoragePaths? paths,
  }) : _client = client ?? http.Client(),
       _paths = paths ?? StoragePaths.instance;

  final ManifestSource source;
  final http.Client _client;
  final StoragePaths _paths;

  bool _cancelled = false;
  void cancel() => _cancelled = true;

  /// True when every file in [manifest] is present and the version matches.
  Future<bool> isInstalled(ModelManifest manifest) async {
    final marker = File('${_paths.modelDir(manifest.id).path}/.version');
    if (!await marker.exists()) return false;
    if ((await marker.readAsString()).trim() != manifest.version) return false;
    for (final f in manifest.files) {
      final file = _paths.modelFile(manifest.id, f.fileName);
      if (!await file.exists()) return false;
      if (await file.length() != f.sizeBytes) return false;
    }
    return true;
  }

  Stream<DownloadProgress> download(ModelManifest manifest) async* {
    _cancelled = false;
    final total = manifest.totalDownloadBytes;
    var completed = 0;

    yield DownloadProgress(
      stage: DownloadStage.resolving,
      receivedBytes: 0,
      totalBytes: total,
    );

    try {
      await _paths.modelDir(manifest.id).create(recursive: true);

      // Resolved late and never cached: presigned URLs are short-lived.
      final resolved = await source.resolve(manifest);

      for (final file in resolved.files) {
        yield* _downloadFile(resolved.id, file, completed, total).map((p) => p);
        completed += file.sizeBytes;
      }

      // The version marker is written last. Its presence is what makes the
      // install "real", so a crash mid-download leaves an incomplete model
      // correctly marked as not installed.
      await File('${_paths.modelDir(manifest.id).path}/.version')
          .writeAsString(manifest.version);

      yield DownloadProgress(
        stage: DownloadStage.done,
        receivedBytes: total,
        totalBytes: total,
      );
    } on DownloadCancelled {
      yield DownloadProgress(
        stage: DownloadStage.cancelled,
        receivedBytes: completed,
        totalBytes: total,
      );
    } catch (e) {
      yield DownloadProgress(
        stage: DownloadStage.failed,
        receivedBytes: completed,
        totalBytes: total,
        error: e,
      );
    }
  }

  Stream<DownloadProgress> _downloadFile(
    String modelId,
    ModelFile file,
    int alreadyDone,
    int grandTotal,
  ) async* {
    final target = _paths.modelFile(modelId, file.fileName);
    final partial = _paths.partialFile(modelId, file.fileName);

    if (await target.exists() && await target.length() == file.sizeBytes) {
      return; // already have it
    }

    var offset = await partial.exists() ? await partial.length() : 0;
    if (offset > file.sizeBytes) {
      // Corrupt or stale partial. Start over rather than guess.
      await partial.delete();
      offset = 0;
    }

    if (offset < file.sizeBytes) {
      final request = http.Request('GET', Uri.parse(file.url!));
      if (offset > 0) request.headers['Range'] = 'bytes=$offset-';

      final response = await _client.send(request);

      // 206 = server honoured the range. 200 with offset>0 means it ignored
      // the header and is sending the whole file, so discard what we had.
      if (response.statusCode == 200 && offset > 0) {
        offset = 0;
        await partial.delete();
      } else if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException(
          'download of ${file.fileName} failed: HTTP ${response.statusCode}',
        );
      }

      final sink = partial.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      final stopwatch = Stopwatch()..start();
      final startOffset = offset;
      var lastEmit = 0;

      try {
        await for (final chunk in response.stream) {
          if (_cancelled) throw DownloadCancelled();
          sink.add(chunk);
          offset += chunk.length;

          // Throttle UI updates. Emitting per-chunk on a fast connection
          // floods the stream and janks the progress bar.
          if (offset - lastEmit >= 1 << 20) {
            lastEmit = offset;
            final elapsed = stopwatch.elapsedMilliseconds / 1000;
            yield DownloadProgress(
              stage: DownloadStage.downloading,
              receivedBytes: alreadyDone + offset,
              totalBytes: grandTotal,
              bytesPerSecond: elapsed > 0
                  ? (offset - startOffset) / elapsed
                  : 0,
            );
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
    }

    yield DownloadProgress(
      stage: DownloadStage.verifying,
      receivedBytes: alreadyDone + file.sizeBytes,
      totalBytes: grandTotal,
    );

    final digest = await _sha256OfFile(partial);
    if (digest != file.sha256) {
      await partial.delete();
      throw ChecksumMismatch(file.fileName, file.sha256, digest);
    }

    // Atomic within the same filesystem. Until this line runs, nothing
    // reading the models directory can mistake the partial for a model.
    await partial.rename(target.path);
  }

  /// Streamed so a 2GB file is never held in memory. On a mid-range phone
  /// this takes a few seconds; show the verifying stage in the UI.
  static Future<String> _sha256OfFile(File file) async {
    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    final digest = output.events.single;
    output.close();
    return digest.toString();
  }
}
