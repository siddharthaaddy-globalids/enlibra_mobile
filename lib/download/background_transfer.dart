import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';

import 'model_downloader.dart' show DownloadCancelled;

/// Moves a file's bytes using the platform's own download service, so the
/// transfer survives the app going to the background.
///
/// An in-process download dies when Android reclaims the app, and a 2.3GB
/// model over a mobile connection gives it plenty of opportunity. This hands
/// the work to an Android foreground service (with the notification Android
/// requires for one) and to `URLSession` background transfers on iOS, both of
/// which keep going once the app is gone.
///
/// The app still owns everything around the transfer -- resolving a fresh
/// pre-signed URL, verifying the result, promoting `.part` to the real name,
/// writing the version marker. This is only the part that moves bytes.
class BackgroundTransfer {
  /// Namespaces our tasks so the package's database and notifications do not
  /// mix them with anything else the app might transfer later.
  static const group = 'enlibra-models';

  /// Configures notifications and reattaches to anything still running.
  ///
  /// Called once at startup, and importantly *before* anything listens for
  /// updates: `start()` replays status and progress that arrived while the app
  /// was suspended, and reschedules tasks the system killed.
  static Future<void> initialise() async {
    FileDownloader().configureNotificationForGroup(
      group,
      // Android requires a visible notification to run a foreground service,
      // so this is not decoration -- without it the download is subject to
      // being killed like any other background work.
      running: const TaskNotification(
        'Downloading {filename}',
        '{progress}  ·  {networkSpeed}  ·  {timeRemaining} left',
      ),
      complete: const TaskNotification('{filename}', 'Download complete'),
      error: const TaskNotification('{filename}', 'Download failed'),
      paused: const TaskNotification('{filename}', 'Download paused'),
      progressBar: true,
    );

    try {
      await FileDownloader().start(autoCleanDatabase: true);
    } catch (e) {
      // Never fatal: the app must still open and let the user chat with a
      // model that is already on disk.
      debugPrint('background downloader failed to start: $e');
    }
  }

  /// Asks for the notification permission Android 13+ needs.
  ///
  /// Declined is survivable rather than fatal -- the download still runs, it
  /// just loses the visible progress and, with it, some of the protection a
  /// foreground service gets from being killed. So this never blocks.
  static Future<void> requestNotificationPermission() async {
    try {
      final status = await FileDownloader().permissions.status(
        PermissionType.notifications,
      );
      if (status != PermissionStatus.granted) {
        await FileDownloader().permissions.request(
          PermissionType.notifications,
        );
      }
    } catch (e) {
      debugPrint('notification permission request failed: $e');
    }
  }

  DownloadTask? _task;

  /// Downloads [url] to `<application support>/[directory]/[fileName]`,
  /// yielding cumulative bytes written.
  ///
  /// [directory] is relative to the application support directory, which is
  /// the same root `StoragePaths` resolves, so the file lands exactly where
  /// the rest of the app expects it.
  Stream<int> fetch({
    required Uri url,
    required String directory,
    required String fileName,
    required int expectedBytes,
    required String displayName,
  }) {
    final controller = StreamController<int>();

    // `urlQueryParameters` is left null deliberately: the package appends
    // those to the URL, and this URL's query *is* an AWS signature. It has to
    // travel through byte for byte.
    final task = DownloadTask(
      url: url.toString(),
      filename: fileName,
      directory: directory,
      baseDirectory: BaseDirectory.applicationSupport,
      group: group,
      updates: Updates.statusAndProgress,
      // Lets the platform suspend and resume rather than restart, which on a
      // file this size is the whole game.
      allowPause: true,
      retries: 3,
      displayName: displayName,
    );
    _task = task;

    FileDownloader()
        .download(
          task,
          onProgress: (progress) {
            // Negative values are status sentinels (failed, canceled, paused),
            // not fractions. The status callback deals with those.
            if (progress >= 0 && !controller.isClosed) {
              controller.add((progress * expectedBytes).round());
            }
          },
        )
        .then((update) {
          if (controller.isClosed) return;
          switch (update.status) {
            case TaskStatus.complete:
              controller.add(expectedBytes);
              controller.close();
            case TaskStatus.canceled:
              controller.addError(DownloadCancelled());
              controller.close();
            default:
              controller.addError(BackgroundTransferException(update));
              controller.close();
          }
        })
        .catchError((Object e) {
          if (!controller.isClosed) {
            controller.addError(e);
            controller.close();
          }
        });

    return controller.stream;
  }

  /// Cancels the in-flight task, including one still running natively after
  /// the app was backgrounded.
  Future<void> cancel() async {
    final task = _task;
    if (task == null) return;
    try {
      await FileDownloader().cancelTaskWithId(task.taskId);
    } catch (e) {
      debugPrint('could not cancel ${task.taskId}: $e');
    }
  }
}

/// A transfer that ended in something other than success.
///
/// Carries the platform's own description where there is one; the package
/// surfaces HTTP status and its own exception type, which is more useful than
/// a bare "download failed".
class BackgroundTransferException implements Exception {
  BackgroundTransferException(this.update);

  final TaskStatusUpdate update;

  @override
  String toString() {
    final code = update.responseStatusCode;
    final detail = update.exception?.description;
    return switch (update.status) {
      TaskStatus.notFound =>
        'The file was not found at that URL${code == null ? '' : ' (HTTP $code)'}.',
      TaskStatus.paused => 'The download was paused and could not be resumed.',
      _ =>
        'The download failed${code == null ? '' : ' (HTTP $code)'}'
            '${detail == null ? '.' : ': $detail'}',
    };
  }
}
