import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

import 'package:multi_ai/addons/code/code_agent_controller.dart';
import 'package:multi_ai/addons/code/code_agent_pane.dart';
import 'package:multi_ai/addons/code/code_engine.dart';
import 'package:multi_ai/addons/code/code_engine_installer.dart' show CodeEngineProgress;
import 'package:multi_ai/addons/code/code_session_store.dart';
import 'package:multi_ai/addons/code/opencode_client.dart';
import 'package:multi_ai/addons/code/project_root_source.dart';
import 'package:multi_ai/api_client.dart';
import 'package:multi_ai/model_pool.dart';

class _FakeApi extends ApiClient {
  @override
  Future<List<ModelInfo>> fetchModels() async =>
      [const ModelInfo(id: 'alpha', name: 'Alpha', gguf: 'hf://x/y/z.gguf')];

  @override
  Future<DeviceSpecs> fetchDeviceSpecs() async => const DeviceSpecs();
}

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

class _FakeRoot implements ProjectRootSource {
  @override
  Future<String?> pickDirectory() async => 'C:/project';
}

class _NoopClient implements OpencodeClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// An engine whose install the test drives by hand.
class _FakeEngine implements CodeEngine {
  bool installed = false;
  bool installable = true;
  int installCalls = 0;

  /// Completes the in-flight [install] (or fails it, if given an error).
  Completer<void>? _gate;

  @override
  final OpencodeClient client = _NoopClient();
  @override
  String providerIdFor(ModelInfo model) => 'p';
  @override
  String modelIdFor(ModelInfo model) => 'm';
  @override
  Future<void> ensureRunning({required ModelInfo model}) async {}
  @override
  Future<bool> isInstalled() async => installed;
  @override
  bool get canInstall => installable;
  @override
  int get installBytes => 98000000;
  @override
  Future<void> stop() async {}

  @override
  Stream<CodeEngineProgress> install() async* {
    installCalls++;
    _gate = Completer<void>();
    yield const CodeEngineProgress('Downloading opencode…', fraction: 0.4);
    await _gate!.future;
    installed = true;
    yield const CodeEngineProgress('Installed opencode.', fraction: 1);
  }

  void finishInstall() => _gate!.complete();
  void failInstall(Object error) => _gate!.completeError(error);
}

Future<CodeAgentController> _controller(_FakeEngine engine) async {
  final pool = ModelPool(api: _FakeApi(), downloadManager: const _AllDownloaded());
  await pool.refresh();
  final controller = CodeAgentController(
    pool: pool,
    projectRootSource: _FakeRoot(),
    store: InMemoryCodeSessionStore(),
    engine: engine,
  )..start();
  await controller.pickProjectRoot();
  controller.selectModel('alpha');
  // start() runs this check without awaiting it; doing it here settles the
  // result without a timer, which a widget test's fake clock would never fire.
  await controller.refreshEngine();
  return controller;
}

Future<void> _pumpPane(WidgetTester tester, CodeAgentController controller) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: CodeAgentPane(controller: controller)),
  ));
  await tester.pump();
}

void main() {
  group('controller', () {
    test('is ready, and can send, when the engine is installed', () async {
      final controller = await _controller(_FakeEngine()..installed = true);
      expect(controller.engineReady, isTrue);
      expect(controller.canSend, isTrue);
    });

    test('is not ready, and cannot send, when it is missing', () async {
      final controller = await _controller(_FakeEngine());
      expect(controller.engineReady, isFalse);
      expect(controller.canSend, isFalse);
    });

    test('is not blocked from sending while the first check is still running', () async {
      final pool = ModelPool(api: _FakeApi(), downloadManager: const _AllDownloaded());
      await pool.refresh();
      final controller = CodeAgentController(
        pool: pool,
        projectRootSource: _FakeRoot(),
        store: InMemoryCodeSessionStore(),
        engine: _FakeEngine()..installed = true,
      );
      await controller.pickProjectRoot();
      controller.selectModel('alpha');
      // No start(), so no check has run: unknown must not read as "missing".
      expect(controller.engineReady, isNull);
      expect(controller.canSend, isTrue);
    });

    test('installing reports progress, then becomes ready', () async {
      final engine = _FakeEngine();
      final controller = await _controller(engine);

      final install = controller.installEngine();
      await Future<void>.delayed(Duration.zero);
      expect(controller.engineInstalling, isTrue);
      expect(controller.engineProgress?.message, 'Downloading opencode…');
      expect(controller.engineProgress?.fraction, 0.4);
      expect(controller.canSend, isFalse);

      engine.finishInstall();
      await install;

      expect(controller.engineInstalling, isFalse);
      expect(controller.engineInstallError, isNull);
      expect(controller.engineReady, isTrue);
      expect(controller.canSend, isTrue);
    });

    test('a failed install surfaces its error and stays not ready', () async {
      final engine = _FakeEngine();
      final controller = await _controller(engine);

      final install = controller.installEngine();
      await Future<void>.delayed(Duration.zero);
      engine.failInstall(StateError('checksum mismatch'));
      await install;

      expect(controller.engineInstalling, isFalse);
      expect(controller.engineInstallError, 'checksum mismatch');
      expect(controller.engineReady, isFalse);
    });

    test('a second install request while one is running is ignored', () async {
      final engine = _FakeEngine();
      final controller = await _controller(engine);

      final first = controller.installEngine();
      await Future<void>.delayed(Duration.zero);
      await controller.installEngine();
      expect(engine.installCalls, 1);

      engine.finishInstall();
      await first;
    });

    test('retrying after a failure clears the old error', () async {
      final engine = _FakeEngine();
      final controller = await _controller(engine);

      var run = controller.installEngine();
      await Future<void>.delayed(Duration.zero);
      engine.failInstall(StateError('offline'));
      await run;
      expect(controller.engineInstallError, 'offline');

      run = controller.installEngine();
      await Future<void>.delayed(Duration.zero);
      expect(controller.engineInstallError, isNull);
      engine.finishInstall();
      await run;
      expect(controller.engineReady, isTrue);
    });

    test('refreshEngine notices programs the user installed themselves', () async {
      final engine = _FakeEngine();
      final controller = await _controller(engine);
      expect(controller.engineReady, isFalse);

      engine.installed = true;
      await controller.refreshEngine();

      expect(controller.engineReady, isTrue);
    });
  });

  group('install card', () {
    testWidgets('is not shown when the engine is installed', (tester) async {
      await _pumpPane(tester, await _controller(_FakeEngine()..installed = true));
      expect(find.text('The Code tab needs two programs'), findsNothing);
    });

    testWidgets('offers the install, with its size, when the engine is missing', (tester) async {
      await _pumpPane(tester, await _controller(_FakeEngine()));

      expect(find.text('The Code tab needs two programs'), findsOneWidget);
      expect(find.text('Install (~98 MB)'), findsOneWidget);
      expect(find.textContaining("this app's own folder"), findsOneWidget);
      // The input points at the card instead of saying "choose a model first".
      expect(find.text('Install the Code engine above first'), findsOneWidget);
    });

    testWidgets('tapping Install shows progress and then the card goes away', (tester) async {
      final engine = _FakeEngine();
      final controller = await _controller(engine);
      await _pumpPane(tester, controller);

      await tester.tap(find.text('Install (~98 MB)'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Downloading opencode…'), findsOneWidget);
      expect(find.text('Install (~98 MB)'), findsNothing);

      engine.finishInstall();
      await tester.pumpAndSettle();

      expect(find.text('The Code tab needs two programs'), findsNothing);
      expect(controller.engineReady, isTrue);
    });

    testWidgets('a failed install shows the reason and a Try again button', (tester) async {
      final engine = _FakeEngine();
      final controller = await _controller(engine);
      await _pumpPane(tester, controller);

      await tester.tap(find.text('Install (~98 MB)'));
      await tester.pump();
      await tester.pump();
      engine.failInstall(StateError('The download did not match its checksum'));
      await tester.pumpAndSettle();

      expect(find.textContaining('did not match its checksum'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('on a platform that cannot install, it explains and offers Check again',
        (tester) async {
      final engine = _FakeEngine()..installable = false;
      final controller = await _controller(engine);
      await _pumpPane(tester, controller);

      expect(find.textContaining('put them on PATH'), findsOneWidget);
      expect(find.textContaining('Install (~'), findsNothing);

      engine.installed = true;
      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();

      expect(find.text('The Code tab needs two programs'), findsNothing);
    });
  });
}
