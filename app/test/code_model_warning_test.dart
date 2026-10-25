import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

import 'package:multi_ai/addons/code/code_addon.dart';
import 'package:multi_ai/addons/code/code_agent_controller.dart';
import 'package:multi_ai/addons/code/code_engine.dart';
import 'package:multi_ai/addons/code/code_engine_installer.dart' show CodeEngineProgress;
import 'package:multi_ai/addons/code/code_session_store.dart';
import 'package:multi_ai/addons/code/opencode_client.dart';
import 'package:multi_ai/api_client.dart';
import 'package:multi_ai/model_pool.dart';

class _FakeApi extends ApiClient {
  _FakeApi(this._models);
  final List<ModelInfo> _models;

  @override
  Future<List<ModelInfo>> fetchModels() async => _models;

  @override
  Future<DeviceSpecs> fetchDeviceSpecs() async => const DeviceSpecs();
}

/// Reports every on-device source as already downloaded, so the models below
/// show up in the Code tab's picker.
class _AllDownloaded extends ThrowingModelDownloadManager {
  const _AllDownloaded();

  @override
  Future<ModelCacheEntry?> get(String cacheKey, {String? cacheDirectory}) async {
    final now = DateTime.now();
    return ModelCacheEntry(
      sourceCanonicalKey: cacheKey,
      cacheKey: cacheKey,
      fileName: 'model.gguf',
      filePath: 'C:/fake/model.gguf',
      createdAt: now,
      updatedAt: now,
    );
  }
}

class _NoopClient implements OpencodeClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeEngine implements CodeEngine {
  @override
  final OpencodeClient client = _NoopClient();
  @override
  String providerIdFor(ModelInfo model) => 'p';
  @override
  String modelIdFor(ModelInfo model) => 'm';
  @override
  Future<void> ensureRunning({required ModelInfo model}) async {}
  @override
  Future<bool> isInstalled() async => true;
  @override
  bool get canInstall => false;
  @override
  Stream<CodeEngineProgress> install() => const Stream.empty();
  @override
  int get installBytes => 0;
  @override
  Future<void> stop() async {}
}

// Each test uses its own model ids: "Use anyway" is remembered for the app's run,
// so reusing one across tests would hide the warning from the later test.
ModelInfo _model(String id, String name) =>
    ModelInfo(id: id, name: name, gguf: 'hf://x/y/$id.gguf');

Future<CodeAgentController> _pump(WidgetTester tester, List<ModelInfo> models) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final pool = ModelPool(api: _FakeApi(models), downloadManager: const _AllDownloaded());
  await pool.refresh();
  final controller = CodeAgentController(
    pool: pool,
    store: InMemoryCodeSessionStore(),
    engine: _FakeEngine(),
  )..start();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 320, child: CodeSidebarPanel(controller: controller)),
    ),
  ));
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('a model that works is selected without any warning', (tester) async {
    final controller = await _pump(tester, [_model('gemma_4_e2b', 'Gemma 4 E2B')]);

    await tester.tap(find.text('Gemma 4 E2B'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.selectedModel?.id, 'gemma_4_e2b');
  });

  testWidgets('an uncertain model is selected without a warning', (tester) async {
    final controller = await _pump(tester, [_model('llama_3_2_1b', 'Llama 3.2 1B')]);

    await tester.tap(find.text('Llama 3.2 1B'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.selectedModel?.id, 'llama_3_2_1b');
  });

  testWidgets('a model that is not in the verdict table is selected without a warning',
      (tester) async {
    final controller = await _pump(tester, [_model('brand_new_model', 'Brand New')]);

    await tester.tap(find.text('Brand New'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.selectedModel?.id, 'brand_new_model');
  });

  testWidgets('a model tested as incompatible warns, and Choose another leaves the selection',
      (tester) async {
    final controller = await _pump(tester, [_model('gemma_3_1b', 'Gemma 3 1B')]);

    await tester.tap(find.text('Gemma 3 1B'));
    await tester.pumpAndSettle();

    expect(find.text("Gemma 3 1B can't use tools"), findsOneWidget);
    expect(find.textContaining('invents its contents'), findsOneWidget);
    expect(controller.selectedModel, isNull, reason: 'not selected until confirmed');

    await tester.tap(find.text('Choose another'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.selectedModel, isNull);
  });

  testWidgets('an untested incompatible model says "probably", and Use anyway selects it',
      (tester) async {
    final controller = await _pump(tester, [_model('gemma_3_4b', 'Gemma 3 4B')]);

    await tester.tap(find.text('Gemma 3 4B'));
    await tester.pumpAndSettle();
    expect(find.text("Gemma 3 4B probably can't use tools"), findsOneWidget);

    await tester.tap(find.text('Use anyway'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.selectedModel?.id, 'gemma_3_4b');
  });

  testWidgets('the warning is not repeated once the user has chosen to use the model anyway',
      (tester) async {
    final controller = await _pump(tester, [
      _model('qwen2_5_coder_1_5b', 'Qwen2.5 Coder 1.5B'),
      _model('qwen3_4b', 'Qwen3 4B'),
    ]);

    await tester.tap(find.text('Qwen2.5 Coder 1.5B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use anyway'));
    await tester.pumpAndSettle();
    expect(controller.selectedModel?.id, 'qwen2_5_coder_1_5b');

    await tester.tap(find.text('Qwen3 4B'));
    await tester.pumpAndSettle();
    expect(controller.selectedModel?.id, 'qwen3_4b');

    await tester.tap(find.text('Qwen2.5 Coder 1.5B'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.selectedModel?.id, 'qwen2_5_coder_1_5b');
  });
}
