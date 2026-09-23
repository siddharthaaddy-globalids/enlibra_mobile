import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/device_tier.dart';
import '../models/gguf_probe.dart';
import '../models/model_link.dart';
import '../models/model_manifest.dart';
import 'theme.dart';

/// Adds a model by pasting a link to it.
///
/// The catalog endpoint is behind Cognito and the app has no login yet, so
/// this is how a model gets onto a device: run `scripts/presign-model.mjs`
/// against the S3 prefix, paste what it prints.
///
/// Nothing is written until the link has been checked. Checking means reading
/// the GGUF's own header over a ranged request -- a couple of megabytes -- so
/// the sheet can state the real size, architecture and RAM cost before the
/// user commits to a multi-gigabyte download over what may be a phone plan.
class AddModelSheet extends StatefulWidget {
  const AddModelSheet({
    super.key,
    required this.device,
    this.existingIds = const {},
  });

  final DeviceCapabilities device;

  /// Ids already installed. A link resolving to one of these is an update, and
  /// the sheet says so rather than looking like a fresh install.
  final Set<String> existingIds;

  /// Returns the manifest to add, or null if dismissed.
  static Future<ModelManifest?> show(
    BuildContext context, {
    required DeviceCapabilities device,
    Set<String> existingIds = const {},
  }) {
    return showModalBottomSheet<ModelManifest>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => AddModelSheet(device: device, existingIds: existingIds),
    );
  }

  @override
  State<AddModelSheet> createState() => _AddModelSheetState();
}

class _AddModelSheetState extends State<AddModelSheet> {
  final _linkController = TextEditingController();
  final _nameController = TextEditingController();
  final _probe = GgufProbe();

  bool _checking = false;
  String? _error;
  ModelManifest? _candidate;
  DateTime? _expiry;

  /// Null when the pasted text was a complete manifest and nothing was
  /// probed, so the question was never asked. False only when a real GGUF was
  /// read and found to have no template.
  bool? _hasChatTemplate;

  @override
  void dispose() {
    _linkController.dispose();
    _nameController.dispose();
    _probe.close();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) return;
    _linkController.text = text.trim();
    if (mounted) setState(() {});
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
      _candidate = null;
      _hasChatTemplate = null;
    });

    try {
      final link = ModelLink.parse(_linkController.text);
      final manifest = await _buildManifest(link);

      if (!mounted) return;
      setState(() {
        _candidate = manifest;
        _expiry = link.earliestExpiry;
        _nameController.text = manifest.displayName;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _readable(e));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// A pasted full manifest already describes the model. Anything else is a
  /// URL to weights, and the weights describe themselves.
  Future<ModelManifest> _buildManifest(ModelLink link) async {
    final existing = link.manifest;
    if (existing != null) return existing;

    final weights = link.weights;
    final probed = await _probe.probe(weights.url);
    _hasChatTemplate = probed.hasChatTemplate;

    final id = link.id ?? ModelLink.idFromUrl(weights.url);
    final manifest = probed.toManifest(
      id: id,
      displayName: link.displayName ?? probed.header.name ?? id,
      sha256: weights.sha256,
      description: link.source,
    );

    // Side-car files (a projector, an adapter) only come from the JSON form,
    // which states their sizes. One without a size cannot be budgeted for, so
    // it is left out rather than silently breaking the progress bar.
    final extras = link.files
        .where((f) => f.url != weights.url && f.sizeBytes != null)
        .map(
          (f) => ModelFile(
            role: f.role,
            fileName: f.fileName ?? f.url.pathSegments.last,
            sizeBytes: f.sizeBytes!,
            sha256: f.sha256,
            url: f.url.toString(),
          ),
        );

    return extras.isEmpty
        ? manifest
        : manifest.withFiles([...manifest.files, ...extras]);
  }

  static String _readable(Object error) {
    if (error is FormatException) return error.message;
    if (error is GgufProbeException) return error.message;
    if (error is ManifestException) return error.message;
    return error.toString();
  }

  void _add() {
    final candidate = _candidate;
    if (candidate == null) return;
    final name = _nameController.text.trim();
    Navigator.of(context).pop(
      name.isEmpty || name == candidate.displayName
          ? candidate
          : _renamed(candidate, name),
    );
  }

  static ModelManifest _renamed(ModelManifest m, String name) => ModelManifest(
    schemaVersion: m.schemaVersion,
    id: m.id,
    displayName: name,
    version: m.version,
    files: m.files,
    quantization: m.quantization,
    shape: m.shape,
    contextLength: m.contextLength,
    chatTemplate: m.chatTemplate,
    stopStrings: m.stopStrings,
    sampling: m.sampling,
    kvCacheType: m.kvCacheType,
    description: m.description,
  );

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final media = MediaQuery.of(context);

    return Padding(
      // Keeps the sheet above the keyboard while a long URL is being pasted.
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTheme.maxContentWidth),
          child: Padding(
            // `useSafeArea` on a modal sheet wraps it in `SafeArea(bottom:
            // false)` -- deliberately, so a sheet can paint to the bottom edge
            // -- which leaves the gesture bar or navigation buttons sitting on
            // top of whatever is last in the column. That is the action row
            // here, so the inset is added back by hand.
            //
            // Summed with the keyboard inset rather than chosen between:
            // `padding.bottom` drops to zero while the keyboard is up, since
            // the keyboard already covers the navigation bar, so exactly one
            // of the two is ever non-zero.
            padding: EdgeInsets.fromLTRB(20, 14, 20, 24 + media.padding.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: t.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Add a model',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Paste a pre-signed download URL, or the JSON that '
                  'scripts/presign-model.mjs writes.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _linkController,
                  minLines: 2,
                  maxLines: 5,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  style: const TextStyle(fontSize: 12.5),
                  decoration: InputDecoration(
                    hintText: 'https://…/model-q4_k_m.gguf?X-Amz-Signature=…',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: 'Paste',
                      icon: const Icon(Icons.content_paste, size: 18),
                      onPressed: _pasteFromClipboard,
                    ),
                  ),
                  onChanged: (_) {
                    if (_candidate != null || _error != null) {
                      setState(() {
                        _candidate = null;
                        _error = null;
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                if (_error != null) ...[
                  _ErrorNote(message: _error!),
                  const SizedBox(height: 12),
                ],
                if (_candidate != null) ...[
                  _Preview(
                    manifest: _candidate!,
                    device: widget.device,
                    expiry: _expiry,
                    isUpdate: widget.existingIds.contains(_candidate!.id),
                    hasChatTemplate: _hasChatTemplate,
                    nameController: _nameController,
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  children: [
                    if (_candidate == null)
                      FilledButton(
                        onPressed: _checking ? null : _check,
                        child: _checking
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Check link'),
                      )
                    else
                      FilledButton(
                        onPressed: _add,
                        child: Text(
                          widget.existingIds.contains(_candidate!.id)
                              ? 'Update model'
                              : 'Add model',
                        ),
                      ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
                if (_checking) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Reading the model header…',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
      ),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: AppColors.danger),
      ),
    );
  }
}

/// What the header said, before anything is downloaded.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.manifest,
    required this.device,
    required this.expiry,
    required this.isUpdate,
    required this.hasChatTemplate,
    required this.nameController,
  });

  final ModelManifest manifest;
  final DeviceCapabilities device;
  final DateTime? expiry;
  final bool isUpdate;

  /// See [ProbedGguf.hasChatTemplate]. Null means it was not determined.
  final bool? hasChatTemplate;

  final TextEditingController nameController;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final usable = device.usableRamBytes;
    final fits = manifest.fitsOn(usable);
    final fittable = manifest.fittableContext(usable);
    final estimate = manifest.memoryAt(fittable > 0 ? fittable : 2048);
    final sizeGb = manifest.totalDownloadBytes / (1024 * 1024 * 1024);
    final params = manifest.shape.paramCount / 1e9;
    final unverified = manifest.files.any((f) => f.sha256 == null);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: nameController,
            style: Theme.of(context).textTheme.titleMedium,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Name',
              border: UnderlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _Chip(label: '${sizeGb.toStringAsFixed(2)} GB download'),
              _Chip(label: '${estimate.totalGb.toStringAsFixed(2)} GB RAM'),
              _Chip(label: manifest.quantization),
              if (params >= 0.1)
                _Chip(label: '${params.toStringAsFixed(1)}B params'),
              _Chip(label: '${manifest.contextLength} ctx'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            fits
                ? 'Runs with a $fittable-token context on this '
                      '${device.totalRamGb.toStringAsFixed(0)}GB device.'
                : 'Too large for this device: it needs '
                      '${estimate.totalGb.toStringAsFixed(1)}GB and only '
                      '${device.usableRamGb.toStringAsFixed(1)}GB is usable.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: fits ? t.textMuted : AppColors.danger),
          ),
          // Loud, and above the softer notes: this one means the model will
          // download and load and then refuse to hold a conversation, which
          // is not something to find out after 2.3GB.
          if (hasChatTemplate == false) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: AppColors.danger.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 15,
                    color: AppColors.danger,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      'No chat template inside this GGUF. It will download '
                      'and load, but chat will fail: the engine uses the '
                      "model's own template and will not guess one. "
                      'Re-convert with the template embedded.',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: AppColors.danger),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (isUpdate) ...[
            const SizedBox(height: 8),
            _Note(
              icon: Icons.refresh,
              text:
                  'Replaces the link for a model already on this device. '
                  'Files already downloaded are kept.',
            ),
          ],
          if (expiry != null) ...[
            const SizedBox(height: 8),
            _Note(icon: Icons.schedule, text: _expiryText(expiry!)),
          ],
          if (unverified) ...[
            const SizedBox(height: 8),
            _Note(
              icon: Icons.info_outline,
              text:
                  'No checksum published, so the download is checked by size '
                  'only. Re-run the script with --checksum for a sha256.',
            ),
          ],
        ],
      ),
    );
  }

  static String _expiryText(DateTime expiry) {
    final left = expiry.difference(DateTime.now().toUtc());
    if (left.isNegative) {
      return 'This link has already expired. Generate a fresh one.';
    }
    if (left.inHours >= 24) {
      return 'Link valid for ${left.inDays} more day(s).';
    }
    if (left.inHours >= 1) {
      return 'Link valid for ${left.inHours}h. Start the download before then.';
    }
    return 'Link expires in ${left.inMinutes} min — start now, or re-sign it.';
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: t.textFaint),
        const SizedBox(width: 7),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: t.surfaceRaised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
          color: t.textMuted,
        ),
      ),
    );
  }
}
