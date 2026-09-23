import 'dart:async';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/manifest_source.dart';
import '../models/model_manifest.dart';
import 'background_transfer.dart';
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

/// The connection stopped delivering bytes without closing or erroring.
///
/// A stalled TCP connection is silent: no error arrives, the stream simply
/// never produces another chunk. Left alone it looks exactly like a download
/// frozen at 7%, which is the least actionable thing an app can show. A
/// watchdog turns it into a failure the user can retry.
class DownloadStalled implements Exception {
  DownloadStalled(this.fileName, this.after);
  final String fileName;
  final Duration after;
  @override
  String toString() =>
      'the connection stopped sending data for ${after.inSeconds}s. '
      'Tap Download to resume from where it stopped.';
}

class ChecksumMismatch implements Exception {
  ChecksumMismatch(this.fileName, this.expected, this.actual);
  final String fileName, expected, actual;
  @override
  String toString() =>
      'ChecksumMismatch($fileName: expected $expected, got $actual)';
}

/// Raised for a file with no published checksum whose download did not come
/// out the length it was supposed to. Weaker than [ChecksumMismatch] -- it
/// catches a truncated or over-long transfer, not a corrupted one.
class SizeMismatch implements Exception {
  SizeMismatch(this.fileName, this.expected, this.actual);
  final String fileName;
  final int expected, actual;
  @override
  String toString() =>
      'SizeMismatch($fileName: expected $expected bytes, got $actual)';
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
    this.background,
    this.stallTimeout = const Duration(seconds: 45),
  }) : _client = client ?? http.Client(),
       _paths = paths ?? StoragePaths.instance;

  /// The platform download service, on the platforms that have one.
  ///
  /// Null falls back to downloading in this process, which is right for
  /// desktop and for tests -- neither needs a transfer that survives the app
  /// being killed, and an in-process download is far easier to reason about.
  final BackgroundTransfer? background;

  /// How long to wait for the next byte before giving up on the connection.
  ///
  /// Generous, because a phone switching between cells can legitimately go
  /// quiet for a while and resuming costs a round trip. But finite: the
  /// alternative is a progress bar that sits at 7% until the app is killed.
  final Duration stallTimeout;

  final ManifestSource source;
  final http.Client _client;
  final StoragePaths _paths;

  /// How often progress is reported while bytes are arriving. Four updates a
  /// second is past the point anyone reads a percentage, and every one of them
  /// costs a frame the socket spends waiting.
  static const _progressIntervalMs = 250;

  bool _cancelled = false;

  /// Tears down the in-flight connection. Set while a response body is being
  /// read, cleared when it finishes.
  void Function()? _abort;

  /// Stops the download.
  ///
  /// Setting a flag is not enough on its own: the flag is only read when a
  /// chunk arrives, so a stalled connection would ignore Cancel for as long as
  /// it stayed stalled -- which is precisely when the user reaches for it. So
  /// this also tears the subscription down directly.
  void cancel() {
    _cancelled = true;
    _abort?.call();
    // Cancels the native task too, which may still be running after the app
    // was backgrounded.
    unawaited(background?.cancel() ?? Future<void>.value());
  }

  /// Wraps [source] so [cancel] can end it immediately rather than at the next
  /// chunk boundary.
  Stream<List<int>> _abortable(Stream<List<int>> source) {
    final controller = StreamController<List<int>>();
    final subscription = source.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
      cancelOnError: true,
    );

    _abort = () {
      subscription.cancel();
      if (!controller.isClosed) {
        controller.addError(DownloadCancelled());
        controller.close();
      }
    };
    controller.onCancel = subscription.cancel;

    return controller.stream;
  }

  /// Bytes this model currently occupies, finished or half-finished.
  ///
  /// Counts the `.part` files too, which is the number that matters when the
  /// question is "what is this failed download costing me".
  Future<int> bytesOnDisk(ModelManifest manifest) async {
    final dir = _paths.modelDir(manifest.id);
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  /// Deletes everything downloaded for [manifest], complete or partial.
  ///
  /// The manifest itself is untouched, so the model stays in the list and can
  /// be downloaded again without pasting a fresh link.
  Future<void> deleteFiles(ModelManifest manifest) =>
      _paths.deleteModel(manifest.id);

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
        // `await for`, not `yield*`. A delegated stream's errors are forwarded
        // straight to the listener and never reach the try/catch around the
        // `yield*`, so with `yield*` every failure here escaped as a stream
        // error instead of becoming a `failed` progress event. The UI's
        // `await for` then threw, leaving the tile showing whatever percentage
        // it had reached, forever, with a Cancel button attached to a download
        // that had already died.
        await for (final progress in _downloadFile(
          resolved.id,
          file,
          completed,
          total,
        )) {
          yield progress;
        }
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
      // Two ways to move the bytes, one contract: when this finishes, the
      // `.part` file holds the whole thing. Verification and promotion below
      // are shared, so the background path cannot skip an integrity check.
      final transfer = background;
      if (transfer != null) {
        yield* _transferInBackground(
          transfer,
          modelId,
          file,
          alreadyDone,
          grandTotal,
        );
      } else {
        yield* _transferInProcess(
          partial,
          file,
          offset,
          alreadyDone,
          grandTotal,
        );
      }
    }

    yield DownloadProgress(
      stage: DownloadStage.verifying,
      receivedBytes: alreadyDone + file.sizeBytes,
      totalBytes: grandTotal,
    );

    // A model added by pasting a pre-signed URL has no published checksum --
    // there is no catalog entry to have carried one. Check the length instead,
    // which still refuses a transfer that was cut short. Weaker, and the
    // difference matters: a corrupted GGUF of the right length reaches
    // llama.cpp and fails there instead of here.
    final expected = file.sha256;
    if (expected == null) {
      final actual = await partial.length();
      if (file.sizeBytes > 0 && actual != file.sizeBytes) {
        await partial.delete();
        throw SizeMismatch(file.fileName, file.sizeBytes, actual);
      }
    } else {
      final digest = await _sha256OfFile(partial);
      if (digest != expected) {
        await partial.delete();
        throw ChecksumMismatch(file.fileName, expected, digest);
      }
    }

    // Atomic within the same filesystem. Until this line runs, nothing
    // reading the models directory can mistake the partial for a model.
    await partial.rename(target.path);
  }

  /// Hands the transfer to the platform's download service, which keeps going
  /// when the app is backgrounded or killed.
  Stream<DownloadProgress> _transferInBackground(
    BackgroundTransfer transfer,
    String modelId,
    ModelFile file,
    int alreadyDone,
    int grandTotal,
  ) async* {
    // The service resumes its own partial state, so progress restarts from
    // whatever it already holds rather than from our file length.
    final bytes = transfer.fetch(
      url: Uri.parse(file.url!),
      directory: _paths.modelDirectoryName(modelId),
      fileName: '${file.fileName}.part',
      expectedBytes: file.sizeBytes,
      displayName: file.fileName,
    );

    final stopwatch = Stopwatch()..start();
    var lastEmitMs = 0;
    int? firstBytes;

    await for (final received in bytes) {
      if (_cancelled) throw DownloadCancelled();
      // Speed is measured from where this session picked up, not from zero --
      // otherwise reattaching to a task that is already 80% done reports an
      // absurd rate and a meaningless ETA.
      firstBytes ??= received;

      final elapsedMs = stopwatch.elapsedMilliseconds;
      if (elapsedMs - lastEmitMs >= _progressIntervalMs) {
        lastEmitMs = elapsedMs;
        final elapsed = elapsedMs / 1000;
        yield DownloadProgress(
          stage: DownloadStage.downloading,
          receivedBytes: alreadyDone + received,
          totalBytes: grandTotal,
          bytesPerSecond: elapsed > 0 ? (received - firstBytes) / elapsed : 0.0,
        );
      }
    }
  }

  /// Downloads in this process, resuming from the partial file's length.
  ///
  /// Used on desktop, and anywhere the platform service is unavailable. Dies
  /// with the app, which is why it is not the mobile default.
  Stream<DownloadProgress> _transferInProcess(
    File partial,
    ModelFile file,
    int offset,
    int alreadyDone,
    int grandTotal,
  ) async* {
    {
      final request = http.Request('GET', Uri.parse(file.url!));
      if (offset > 0) request.headers['Range'] = 'bytes=$offset-';

      // A server that accepts the connection and then never answers would
      // otherwise hang here with no progress to show and nothing to cancel.
      final http.StreamedResponse response;
      try {
        response = await _client.send(request).timeout(stallTimeout);
      } on TimeoutException {
        throw DownloadStalled(file.fileName, stallTimeout);
      }

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
      var lastEmitMs = 0;

      // `timeout` resets on every chunk, so this fires only when the
      // connection has genuinely gone quiet, not when it is merely slow.
      final body = _abortable(response.stream.timeout(stallTimeout));

      try {
        await for (final chunk in body) {
          if (_cancelled) throw DownloadCancelled();
          sink.add(chunk);
          offset += chunk.length;

          // Throttled by *time*, not by bytes downloaded.
          //
          // This is a generator: `yield` suspends reading from the socket
          // until the listener has consumed the event, and the listener
          // rebuilds the models screen. So the emit rate is not merely a UI
          // concern -- it is a ceiling on download throughput. Throttling per
          // megabyte ties that ceiling to connection speed exactly backwards:
          // the faster the link, the more rebuilds per second it has to wait
          // for. A fixed interval bounds the work at ~4 rebuilds a second
          // whether the link runs at 200KB/s or 50MB/s.
          final elapsedMs = stopwatch.elapsedMilliseconds;
          if (elapsedMs - lastEmitMs >= _progressIntervalMs) {
            lastEmitMs = elapsedMs;
            final elapsed = elapsedMs / 1000;
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
      } on TimeoutException {
        throw DownloadStalled(file.fileName, stallTimeout);
      } finally {
        _abort = null;
        // Whatever arrived is kept, not discarded: the partial file is what
        // makes the retry a resume.
        await sink.flush();
        await sink.close();
      }
    }
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
