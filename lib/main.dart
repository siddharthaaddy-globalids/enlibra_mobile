import 'dart:io';

import 'package:flutter/material.dart';

import 'chat/chat_controller.dart';
import 'core/device_tier.dart';
import 'db/app_database.dart';
import 'db/chat_repository.dart';
import 'download/model_downloader.dart';
import 'download/storage_paths.dart';
import 'llama/fake_llama_engine.dart';
import 'llama/llama_engine.dart';
import 'models/manifest_source.dart';
import 'models/model_manifest.dart';
import 'ui/chat_screen.dart';
import 'ui/models_screen.dart';

/// Backend that holds the AWS credentials and issues presigned S3 URLs.
/// Override at build time:
///   flutter run --dart-define=ENLIBRA_API=https://api.example.com/v1/
///
/// This is a URL, not a secret. Never put an AWS key behind --dart-define:
/// those values sit in the compiled binary in plain text.
const _apiBase = String.fromEnvironment(
  'ENLIBRA_API',
  defaultValue: 'https://api.example.com/v1/',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await StoragePaths.init();
  final database = await AppDatabase.open();

  runApp(
    EnlibraApp(
      repository: ChatRepository(database.db),
      device: DeviceCapabilities.detect(),
    ),
  );
}

class EnlibraApp extends StatelessWidget {
  const EnlibraApp({super.key, required this.repository, required this.device});

  final ChatRepository repository;
  final DeviceCapabilities device;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Enlibra',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomePage(repository: repository, device: device),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.repository, required this.device});

  final ChatRepository repository;
  final DeviceCapabilities device;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Swap for the llama.cpp FFI engine once the binding exists. Nothing else
  // in the app changes.
  final LlamaEngine _engine = FakeLlamaEngine();

  late final ManifestSource _source = BackendManifestSource(
    baseUrl: Uri.parse(_apiBase),
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
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return ModelsScreen(
      catalog: catalog,
      downloader: _downloader,
      device: widget.device,
      onReady: _startChat,
    );
  }
}
