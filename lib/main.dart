import 'dart:io';

import 'package:flutter/material.dart';

import 'chat/chat_controller.dart';
import 'core/device_tier.dart';
import 'db/app_database.dart';
import 'db/chat_repository.dart';
import 'download/model_downloader.dart';
import 'download/storage_paths.dart';
import 'llama/fake_llama_engine.dart';
import 'llama/llama_ffi_engine.dart';
import 'llama/llama_engine.dart';
import 'models/manifest_source.dart';
import 'models/manual_model_source.dart';
import 'models/model_manifest.dart';
import 'ui/add_model_sheet.dart';
import 'ui/app_logo.dart';
import 'ui/chat_screen.dart';
import 'ui/models_screen.dart';
import 'ui/theme.dart';
import 'ui/theme_controller.dart';

/// Backend that holds the AWS credentials and issues presigned S3 URLs.
/// Override at build time:
///   flutter run --dart-define=ENLIBRA_API=https://api.example.com/v1/
///
/// This is a URL, not a secret. Never put an AWS key behind --dart-define:
/// those values sit in the compiled binary in plain text.
///
/// Until that API is reachable -- it is behind Cognito, which the app does not
/// speak yet -- models are added by pasting a pre-signed link. See
/// `scripts/presign-model.mjs` and [ManualModelStore].
const _apiBase = String.fromEnvironment(
  'ENLIBRA_API',
  defaultValue: 'https://api.example.com/v1/',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await StoragePaths.init();
  final database = await AppDatabase.open();
  final theme = await ThemeController.load();
  final manualModels = await ManualModelStore.load();

  runApp(
    EnlibraApp(
      repository: ChatRepository(database.db),
      device: DeviceCapabilities.detect(),
      theme: theme,
      manualModels: manualModels,
    ),
  );
}

class EnlibraApp extends StatelessWidget {
  const EnlibraApp({
    super.key,
    required this.repository,
    required this.device,
    required this.theme,
    required this.manualModels,
  });

  final ChatRepository repository;
  final DeviceCapabilities device;
  final ThemeController theme;
  final ManualModelStore manualModels;

  @override
  Widget build(BuildContext context) {
    // Rebuilds the whole app when the mode changes, which is cheap and
    // avoids threading the controller through every widget that only wants
    // to read the current brightness.
    return ListenableBuilder(
      listenable: theme,
      builder: (context, _) => MaterialApp(
        title: 'Enlibra',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: theme.mode,
        home: HomePage(
          repository: repository,
          device: device,
          theme: theme,
          manualModels: manualModels,
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.repository,
    required this.device,
    required this.theme,
    required this.manualModels,
  });

  final ChatRepository repository;
  final DeviceCapabilities device;
  final ThemeController theme;
  final ManualModelStore manualModels;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // The real engine unless explicitly asked for the simulator:
  //   flutter run --dart-define=USE_FAKE_ENGINE=true
  // The fake needs no native build, so UI work can proceed on a machine
  // without an NDK or Xcode toolchain.
  static const _useFakeEngine = bool.fromEnvironment('USE_FAKE_ENGINE');

  final LlamaEngine _engine = _useFakeEngine
      ? FakeLlamaEngine()
      : LlamaFfiEngine();

  late final ManualModelSource _manual = ManualModelSource(widget.manualModels);

  /// Pasted-in models first, then whatever the backend offers. The backend is
  /// not reachable without a login, so in practice the first list is the one
  /// that has anything in it -- but the catalog path stays wired up so it
  /// starts working the moment authentication lands, with no change here.
  late final ManifestSource _source = CompositeManifestSource(
    manual: _manual,
    remote: BackendManifestSource(baseUrl: Uri.parse(_apiBase)),
  );
  late final ModelDownloader _downloader = ModelDownloader(source: _source);

  List<ModelManifest>? _catalog;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  Future<void> _loadCatalog() async {
    try {
      final catalog = await _source.catalog();
      if (mounted) setState(() => _catalog = catalog);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _addModel() async {
    final manifest = await AddModelSheet.show(
      context,
      device: widget.device,
      existingIds: widget.manualModels.models.map((m) => m.id).toSet(),
    );
    if (manifest == null) return;
    await widget.manualModels.upsert(manifest);
    await _loadCatalog();
  }

  Future<void> _removeModel(ModelManifest manifest) async {
    await widget.manualModels.remove(manifest.id);
    // The weights are the expensive thing on a phone's storage, so removing a
    // model removes the files too rather than just forgetting the link.
    await StoragePaths.instance.deleteModel(manifest.id);
    await _loadCatalog();
  }

  Future<void> _startChat(ModelManifest manifest, int contextLength) async {
    await _engine.load(
      EngineConfig(
        modelPath: StoragePaths.instance
            .modelFile(manifest.id, manifest.weightsFile.fileName)
            .path,
        manifest: manifest,
        contextLength: contextLength,
        threadCount: _threadCount(),
      ),
    );

    final conversation = await widget.repository.createConversation(
      modelId: manifest.id,
      systemPrompt: 'You are a concise, helpful assistant.',
    );

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          themeController: widget.theme,
          controller: ChatController(
            engine: _engine,
            repository: widget.repository,
            manifest: manifest,
            conversation: conversation,
            contextLength: contextLength,
          ),
        ),
      ),
    );
  }

  /// Performance cores only. On a big.LITTLE Android SoC, handing llama.cpp
  /// every core is slower than handing it half, because each decode batch
  /// waits on the efficiency cores to finish their share.
  static int _threadCount() {
    final cores = Platform.numberOfProcessors;
    if (Platform.isAndroid || Platform.isIOS) {
      return (cores / 2).ceil().clamp(2, 6);
    }
    return (cores - 2).clamp(2, 8);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.device.tier == DeviceTier.unsupported) {
      return const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'This device does not have enough memory to run a model '
              'on-device.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Could not load the model catalog.\n$_error',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  setState(() => _error = null);
                  _loadCatalog();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final catalog = _catalog;
    if (catalog == null) {
      // Branded rather than a bare spinner: this frame is the first thing
      // after the launcher icon, and the catalog read can take a moment.
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppMark(height: 56),
              SizedBox(height: 28),
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ),
        ),
      );
    }

    return ModelsScreen(
      catalog: catalog,
      downloader: _downloader,
      device: widget.device,
      onReady: _startChat,
      themeController: widget.theme,
      onAddModel: _addModel,
      onRemoveModel: _removeModel,
      manualIds: widget.manualModels.models.map((m) => m.id).toSet(),
      allowWithoutDownload: _useFakeEngine,
    );
  }
}
