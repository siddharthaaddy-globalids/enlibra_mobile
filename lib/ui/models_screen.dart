import 'package:flutter/material.dart';

import '../core/device_tier.dart';
import '../download/model_downloader.dart';
import '../models/model_manifest.dart';

/// Lists the catalog, shows what each model costs in download size and RAM,
/// and refuses the ones this device cannot run.
class ModelsScreen extends StatefulWidget {
  const ModelsScreen({
    super.key,
    required this.catalog,
    required this.downloader,
    required this.device,
    required this.onReady,
  });

  final List<ModelManifest> catalog;
  final ModelDownloader downloader;
  final DeviceCapabilities device;
  final void Function(ModelManifest manifest, int contextLength) onReady;

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
    return Scaffold(
      appBar: AppBar(title: const Text('Models')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.memory),
              title: Text(widget.device.toString()),
              subtitle: Text(
                'Models are offered only if they fit in '
                '${widget.device.usableRamGb.toStringAsFixed(1)}GB.',
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final m in widget.catalog) _tile(m),
        ],
      ),
    );
  }

  Widget _tile(ModelManifest manifest) {
    final usable = widget.device.usableRamBytes;
    final fits = manifest.fitsOn(usable);
    final context_ = manifest.fittableContext(usable);
    final estimate = manifest.memoryAt(context_ > 0 ? context_ : 2048);
    final progress = _progress[manifest.id];
    final installed = _installed.contains(manifest.id);
    final downloading =
        progress != null &&
        (progress.stage == DownloadStage.downloading ||
            progress.stage == DownloadStage.verifying ||
            progress.stage == DownloadStage.resolving);

    final downloadGb = manifest.totalDownloadBytes / (1024 * 1024 * 1024);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
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
                  const Chip(
                    label: Text('Installed'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            if (manifest.description != null) ...[
              const SizedBox(height: 4),
              Text(
                manifest.description!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '${downloadGb.toStringAsFixed(2)} GB download  ·  '
              '${estimate.totalGb.toStringAsFixed(2)} GB RAM  ·  '
              '${manifest.quantization}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (fits)
              Text(
                'Runs with a $context_-token context on this device.',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              Text(
                'Too large for this device.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 12),
            if (downloading) ...[
              LinearProgressIndicator(value: progress.fraction),
              const SizedBox(height: 6),
              Text(
                progress.stage == DownloadStage.verifying
                    // Hashing 2GB takes seconds on a phone; say so rather
                    // than letting the bar sit at 100% looking stuck.
                    ? 'Verifying download'
                    : '${(progress.fraction * 100).toStringAsFixed(0)}%'
                          '${progress.eta != null ? '  ·  ${progress.eta!.inMinutes} min left' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: widget.downloader.cancel,
                child: const Text('Cancel'),
              ),
            ] else
              Row(
                children: [
                  if (installed)
                    FilledButton(
                      onPressed: () => widget.onReady(manifest, context_),
                      child: const Text('Use'),
                    )
                  else
                    FilledButton(
                      onPressed: fits ? () => _download(manifest) : null,
                      child: const Text('Download'),
                    ),
                  const SizedBox(width: 8),
                  if (installed)
                    TextButton(
                      onPressed: () async {
                        await widget.downloader
                            .download(manifest)
                            .drain<void>();
                      },
                      child: const Text('Re-verify'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
