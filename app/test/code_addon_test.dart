import 'dart:async';
import 'dart:io';

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
import 'package:multi_ai/addons/code/tool_approval.dart';
import 'package:multi_ai/api_client.dart';
import 'package:multi_ai/model_pool.dart';

class _FakeApi extends ApiClient {
  _FakeApi(this._models);
  final List<ModelInfo> _models;

  @override
  Future<List<ModelInfo>> fetchModels() async => _models;

  @override
  Future<DeviceSpecs> fetchDeviceSpecs() async => const DeviceSpecs();

  @override
  Future<ServerModelCacheStatus> getServerModelCacheStatus(
    String modelId,
  ) async => const ServerModelCacheStatus(cached: true);
}

class _NoDownloads extends ThrowingModelDownloadManager {
  const _NoDownloads();

  @override
  Future<ModelCacheEntry?> get(
    String cacheKey, {
    String? cacheDirectory,
  }) async => null;
}

/// Fake picker — no real dialog blocks under `flutter test`, matching how
/// AttachmentSource is faked for chat's widget tests.
class _FakeRootSource implements ProjectRootSource {
  _FakeRootSource(this.path);
  final String path;

  @override
  Future<String?> pickDirectory() async => path;
}

/// A controllable double for opencode's HTTP/SSE API — see the identical
/// class in code_agent_controller_test.dart for the full rationale; kept
/// separate here since these two test files don't otherwise share code
/// (mirrors how the old `_RecordingApi` was duplicated between them too).
class _FakeOpencodeClient implements OpencodeClient {
  final _events = StreamController<OpencodeEvent>.broadcast();
  int _nextSessionId = 1;
  String? lastCreatedSessionId;

  void emit(OpencodeEvent event) => _events.add(event);

  @override
  Future<String> createSession(String projectRoot) async {
    final id = 'ses_${_nextSessionId++}';
    lastCreatedSessionId = id;
    return id;
  }

  @override
  Future<void> sendMessageAsync({
    required String projectRoot,
    required String sessionId,
    required String providerId,
    required String modelId,
    required String text,
  }) async {}

  @override
  Future<void> respondToPermission({
    required String projectRoot,
    required String permissionId,
    required ToolApprovalDecision decision,
  }) async {}

  @override
  Future<void> abort({
    required String projectRoot,
    required String sessionId,
  }) async {}

  @override
  Stream<OpencodeEvent> events(String projectRoot) => _events.stream;

  @override
  Future<void> close() async {}
}

class _FakeCodeEngine implements CodeEngine {
  _FakeCodeEngine(this.client);

  @override
  final OpencodeClient client;
  @override
  String providerIdFor(ModelInfo model) => 'fake-provider';
  @override
  String modelIdFor(ModelInfo model) => 'fake-model';

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

OpencodePartEvent _toolPart(
  String sessionId,
  String callId,
  String tool, {
  required String status,
  Map<String, dynamic> input = const {},
  String? output,
}) => OpencodePartEvent(sessionId, {
  'id': 'prt_$callId',
  'sessionID': sessionId,
  'messageID': 'msg_1',
  'type': 'tool',
  'callID': callId,
  'tool': tool,
  'state': {'status': status, 'input': input, 'output': ?output},
});

OpencodePartEvent _textPart(String sessionId, String partId, String text) =>
    OpencodePartEvent(sessionId, {
      'id': partId,
      'sessionID': sessionId,
      'messageID': 'msg_1',
      'type': 'text',
      'text': text,
    });

const _alpha = ModelInfo(id: 'alpha', name: 'Alpha');

Future<void> _letSendReachTheCompleter() => Future<void>.delayed(Duration.zero);

Future<(CodeAgentController, _FakeOpencodeClient, Directory)> _buildReady(
  WidgetTester tester,
) async {
  final root = await Directory.systemTemp.createTemp('code_addon_widget_test');
  final api = _FakeApi([_alpha]);
  final pool = ModelPool(api: api, downloadManager: const _NoDownloads());
  await pool.refresh();
  final client = _FakeOpencodeClient();
  final controller = CodeAgentController(
    pool: pool,
    projectRootSource: _FakeRootSource(root.path),
    store: InMemoryCodeSessionStore(),
    engine: _FakeCodeEngine(client),
  )..start();
  await controller.pickProjectRoot();
  controller.selectModel('alpha');

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: CodeAgentPane(controller: controller)),
    ),
  );
  await tester.pump();

  return (controller, client, root);
}

void main() {
  // Every test body below runs inside tester.runAsync(): the fake client's
  // event stream and the controller's awaited completers are real async
  // gaps outside Flutter's fake clock, which otherwise never let them
  // resolve — see https://api.flutter.dev/flutter/flutter_test/WidgetTester/runAsync.html.
  // pumpWidget/pump/tap all still work as normal from inside that callback.

  testWidgets(
    'a completed tool-call turn renders a collapsed row and the final answer',
    (tester) async {
      await tester.runAsync(() async {
        final (controller, client, root) = await _buildReady(tester);
        addTearDown(() => root.delete(recursive: true));

        final run = controller.send('list the files');
        await _letSendReachTheCompleter();
        final sessionId = client.lastCreatedSessionId!;
        client.emit(
          _toolPart(
            sessionId,
            'call_1',
            'list',
            status: 'completed',
            output: 'a.txt',
          ),
        );
        client.emit(_textPart(sessionId, 'prt_1', 'Found some files.'));
        client.emit(OpencodeSessionIdleEvent(sessionId));
        await run;
        await tester.pumpAndSettle();

        // Collapsed by default: the tool name is visible, the JSON arguments
        // and result are not until it's expanded.
        expect(find.textContaining('list'), findsWidgets);
        expect(find.text('Found some files.'), findsOneWidget);
        expect(
          find.text('Done', skipOffstage: false),
          findsOneWidget,
        ); // status chip

        await tester.tap(find.textContaining('list('));
        await tester.pumpAndSettle();

        expect(find.textContaining('a.txt'), findsWidgets);
      });
    },
  );

  testWidgets(
    'a gated tool call shows the approval dialog, and Deny refuses it',
    (tester) async {
      await tester.runAsync(() async {
        final (controller, client, root) = await _buildReady(tester);
        addTearDown(() => root.delete(recursive: true));

        unawaited(controller.send('write a file'));
        await _letSendReachTheCompleter();
        final sessionId = client.lastCreatedSessionId!;
        client.emit(_toolPart(sessionId, 'call_1', 'write', status: 'pending'));
        client.emit(OpencodePermissionEvent(sessionId, 'per_1', 'call_1'));
        await _letSendReachTheCompleter();
        await tester.pumpAndSettle();

        expect(find.text('Approve action'), findsOneWidget);
        expect(find.textContaining('write'), findsWidgets);

        await tester.tap(find.text('Deny'));
        await _letSendReachTheCompleter();
        client.emit(_textPart(sessionId, 'prt_1', 'Okay, skipping that.'));
        client.emit(OpencodeSessionIdleEvent(sessionId));
        await _letSendReachTheCompleter();
        await tester.pumpAndSettle();

        expect(find.text('Approve action'), findsNothing);
        expect(find.text('Okay, skipping that.'), findsOneWidget);
      });
    },
  );

  testWidgets(
    'Allow once on a gated call closes the dialog and lets the turn finish',
    (tester) async {
      await tester.runAsync(() async {
        final (controller, client, root) = await _buildReady(tester);
        addTearDown(() => root.delete(recursive: true));

        unawaited(controller.send('write a file'));
        await _letSendReachTheCompleter();
        final sessionId = client.lastCreatedSessionId!;
        client.emit(_toolPart(sessionId, 'call_1', 'write', status: 'pending'));
        client.emit(OpencodePermissionEvent(sessionId, 'per_1', 'call_1'));
        await _letSendReachTheCompleter();
        await tester.pumpAndSettle();

        expect(find.text('Approve action'), findsOneWidget);

        await tester.tap(find.text('Allow once'));
        await _letSendReachTheCompleter();
        client.emit(
          _toolPart(
            sessionId,
            'call_1',
            'write',
            status: 'completed',
            output: 'wrote it',
          ),
        );
        client.emit(_textPart(sessionId, 'prt_1', 'Done.'));
        client.emit(OpencodeSessionIdleEvent(sessionId));
        await _letSendReachTheCompleter();
        await tester.pumpAndSettle();

        expect(find.text('Approve action'), findsNothing);
        expect(find.text('Done.'), findsOneWidget);
      });
    },
  );
}
