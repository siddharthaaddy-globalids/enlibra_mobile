import 'package:flutter/material.dart';

import '../core/device_tier.dart';
import '../download/model_downloader.dart';
import '../models/model_manifest.dart';
import 'app_logo.dart';
import 'theme.dart';
import 'theme_controller.dart';

/// Lists the catalog, shows what each model costs in download size and RAM,
/// and refuses the ones this device cannot run.
class ModelsScreen extends StatefulWidget {
  const ModelsScreen({
    super.key,
    required this.catalog,
    required this.downloader,
    required this.device,
    required this.onReady,
    required this.themeController,
    required this.onAddModel,
    required this.onRemoveModel,
    this.manualIds = const {},
    this.allowWithoutDownload = false,
  });

  final List<ModelManifest> catalog;
  final ModelDownloader downloader;
  final DeviceCapabilities device;
  final void Function(ModelManifest manifest, int contextLength) onReady;
  final ThemeController themeController;

  /// Opens the add-by-link sheet. Held by the owner, which is what persists
  /// the result and rebuilds the catalog.
  final Future<void> Function() onAddModel;

  final Future<void> Function(ModelManifest manifest) onRemoveModel;

  /// Ids that came from a pasted link rather than the catalog. Only these can
  /// be removed -- a catalog entry is not the device's to delete.
  final Set<String> manualIds;

  /// Lets a model be opened without downloading it. Set only when running
  /// against FakeLlamaEngine, which never touches the weights -- it is the
  /// difference between the app being demoable on a fresh clone and
  /// dead-ending at a download that needs a backend.
  final bool allowWithoutDownload;

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  final Map<String, DownloadProgress> _progress = {};
  final Set<String> _installed = {};

  @override
  void initState() {
    super.initState();
    _refreshInstalled();
  }

  @override
  void didUpdateWidget(ModelsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A model added by link arrives as a new catalog, and it may already be on
    // disk -- re-pasting a refreshed URL for a model downloaded last week
    // should show "Installed", not offer to download it again.
    if (!identical(oldWidget.catalog, widget.catalog)) _refreshInstalled();
  }

  Future<void> _refreshInstalled() async {
    final found = <String>{};
    for (final m in widget.catalog) {
      if (await widget.downloader.isInstalled(m)) found.add(m.id);
    }
    if (!mounted) return;
    setState(() {
      _installed
        ..clear()
        ..addAll(found);
    });
  }

  /// Throws away the bytes on disk but keeps the model and its link.
  ///
  /// Distinct from [_remove] on purpose. The common case is a download that
  /// went wrong -- stalled, or a partial file that is not trusted -- where the
  /// link is still perfectly good and re-pasting a pre-signed URL is a chore.
  /// Removing the model to clear 400MB of half a file is the wrong trade.
  Future<void> _deleteFiles(ModelManifest manifest) async {
    final onDisk = await widget.downloader.bytesOnDisk(manifest);
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete downloaded files?'),
        content: Text(
          onDisk == 0
              ? 'Nothing has been downloaded for '
                    '${manifest.displayName} yet.'
              : 'Frees ${_formatBytes(onDisk)}. '
                    '${manifest.displayName} stays in the list with its '
                    'download link, so you can start again from scratch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Stop first. Deleting the file out from under a live download leaves the
    // writer appending to an unlinked handle, and the next resume would then
    // measure a file that is not there.
    widget.downloader.cancel();
    await widget.downloader.deleteFiles(manifest);

    if (!mounted) return;
    setState(() {
      _installed.remove(manifest.id);
      _progress.remove(manifest.id);
    });
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  }

  Future<void> _remove(ModelManifest manifest) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${manifest.displayName}?'),
        content: const Text(
          'Deletes the downloaded files, the download link, and every chat '
          'held against this model. Adding it back means pasting a link '
          'again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.onRemoveModel(manifest);
    if (!mounted) return;

    // Clearing `_progress` matters as much as clearing `_installed`.
    //
    // The map is keyed by model id, and a model id is derived from the URL --
    // so re-pasting the same link produces the *same* id and the tile picks
    // the stale entry straight back up. The symptom is a freshly added model
    // that opens showing the percentage the deleted one had reached, which
    // looks exactly like a download cache that was never cleared.
    setState(() {
      _installed.remove(manifest.id);
      _progress.remove(manifest.id);
    });
  }

  Future<void> _download(ModelManifest manifest) async {
    await for (final p in widget.downloader.download(manifest)) {
      if (!mounted) return;
      setState(() => _progress[manifest.id] = p);
      if (p.stage == DownloadStage.done) {
        setState(() => _installed.add(manifest.id));
      }
      if (p.stage == DownloadStage.failed && mounted) {
        final error = p.error;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            // An expired link and a stalled connection are the two common
            // failures here, and both already say what to do about them. Shown
            // as written rather than buried behind "Download failed:".
            content: Text(switch (error) {
              ManifestException e => e.message,
              DownloadStalled e => '$e',
              _ => 'Download failed: $error',
            }),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Scaffold(
      appBar: AppBar(
        title: const AppLogo(height: 22),
        actions: [
          IconButton(
            tooltip: 'Add a model by link',
            icon: const Icon(Icons.add),
            onPressed: widget.onAddModel,
          ),
          ThemeToggleButton(controller: widget.themeController),
          const SizedBox(width: 4),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTheme.maxContentWidth),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Row(
                children: [
                  Icon(Icons.memory_outlined, size: 15, color: t.textFaint),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${widget.device.totalRamGb.toStringAsFixed(0)}GB device'
                      '  ·  ${widget.device.usableRamGb.toStringAsFixed(1)}GB '
                      'usable by this app',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (widget.catalog.isEmpty) _emptyState(),
              for (final m in widget.catalog) ...[
                _tile(m),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('No models yet', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Add one with a pre-signed download link. '
            'scripts/presign-model.mjs mints one from an S3 prefix.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: widget.onAddModel,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a model'),
          ),
        ],
      ),
    );
  }

  Widget _tile(ModelManifest manifest) {
    final t = context.tokens;
    final usable = widget.device.usableRamBytes;
    final fits = manifest.fitsOn(usable);
    final fittable = manifest.fittableContext(usable);
    final estimate = manifest.memoryAt(fittable > 0 ? fittable : 2048);
    final progress = _progress[manifest.id];
    final installed =
        _installed.contains(manifest.id) || widget.allowWithoutDownload;
    final downloading =
        progress != null &&
        (progress.stage == DownloadStage.downloading ||
            progress.stage == DownloadStage.verifying ||
            progress.stage == DownloadStage.resolving);

    final downloadGb = manifest.totalDownloadBytes / (1024 * 1024 * 1024);

    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.border),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  manifest.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (installed)
                _Tag(
                  label: widget.allowWithoutDownload
                      ? 'Simulated'
                      : 'Installed',
                  accent: true,
                ),
              if (widget.manualIds.contains(manifest.id))
                PopupMenuButton<String>(
                  tooltip: 'Model options',
                  icon: Icon(Icons.more_horiz, size: 18, color: t.textFaint),
                  onSelected: (choice) {
                    if (choice == 'relink') widget.onAddModel();
                    if (choice == 'clear') _deleteFiles(manifest);
                    if (choice == 'remove') _remove(manifest);
                  },
                  itemBuilder: (_) => const [
                    // Pre-signed links expire; re-pasting one is routine
                    // rather than exceptional, so it lives here and not
                    // only in the error message.
                    PopupMenuItem(
                      value: 'relink',
                      child: Text('Update download link'),
                    ),
                    PopupMenuItem(
                      value: 'clear',
                      child: Text('Delete downloaded files'),
                    ),
                    PopupMenuItem(value: 'remove', child: Text('Remove model')),
                  ],
                ),
            ],
          ),
          if (manifest.description != null) ...[
            const SizedBox(height: 5),
            Text(
              manifest.description!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _Tag(label: '${downloadGb.toStringAsFixed(2)} GB download'),
              _Tag(label: '${estimate.totalGb.toStringAsFixed(2)} GB RAM'),
              _Tag(label: manifest.quantization),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            fits
                ? 'Runs with a $fittable-token context on this device.'
                : 'Too large for this device.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: fits ? t.textMuted : AppColors.danger),
          ),
          const SizedBox(height: 16),
          if (downloading) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress.fraction,
                minHeight: 5,
              ),
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                Expanded(
                  child: Text(
                    progress.stage == DownloadStage.verifying
                        // Hashing 2GB takes seconds on a phone; say so rather
                        // than letting the bar sit at 100% looking stuck.
                        ? 'Verifying download'
                        : '${(progress.fraction * 100).toStringAsFixed(0)}%'
                              '${progress.eta != null ? '  ·  ${progress.eta!.inMinutes} min left' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: widget.downloader.cancel,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ] else
            Row(
              children: [
                if (installed)
                  FilledButton(
                    onPressed: () => widget.onReady(manifest, fittable),
                    child: const Text('Start chat'),
                  )
                else
                  FilledButton(
                    onPressed: fits ? () => _download(manifest) : null,
                    child: const Text('Download'),
                  ),
                const SizedBox(width: 6),
                if (installed && !widget.allowWithoutDownload)
                  TextButton(
                    onPressed: () async {
                      await widget.downloader.download(manifest).drain<void>();
                    },
                    child: const Text('Re-verify'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent ? AppColors.accentSubtle : t.surfaceRaised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accent ? Colors.transparent : t.border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
          color: accent ? t.accent : t.textMuted,
        ),
      ),
    );
  }
}
