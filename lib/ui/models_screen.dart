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
    this.allowWithoutDownload = false,
  });

  final List<ModelManifest> catalog;
  final ModelDownloader downloader;
  final DeviceCapabilities device;
  final void Function(ModelManifest manifest, int contextLength) onReady;
  final ThemeController themeController;

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

  Future<void> _refreshInstalled() async {
    for (final m in widget.catalog) {
      if (await widget.downloader.isInstalled(m)) _installed.add(m.id);
    }
    if (mounted) setState(() {});
  }

  Future<void> _download(ModelManifest manifest) async {
    await for (final p in widget.downloader.download(manifest)) {
      if (!mounted) return;
      setState(() => _progress[manifest.id] = p);
      if (p.stage == DownloadStage.done) {
        setState(() => _installed.add(manifest.id));
      }
      if (p.stage == DownloadStage.failed && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Download failed: ${p.error}')));
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
