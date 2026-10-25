import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

import 'package:multi_ai/addons/code/code_agent_controller.dart';
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

/// Reports every on-device (GGUF) source as already cached — unlike
/// [_NoDownloads], for tests that need `ModelPool.downloaded` to include a
/// GGUF-declaring [ModelInfo] (`ModelPool.isDownloaded` checks this manager
/// directly for those, not the server cache-status API).
class _FakeDownloads extends ThrowingModelDownloadManager {
  const _FakeDownloads();

  @override
  Future<ModelCacheEntry?> get(
    String cacheKey, {
    String? cacheDirectory,
  }) async {
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

class _FakeRootSource implements ProjectRootSource {
  _FakeRootSource(this.path);
  final String? path;

  @override
  Future<String?> pickDirectory() async => path;
}

/// Returns each path in [paths] in order, one per call, then repeats the
/// last one — for tests exercising a second `pickProjectRoot()` that lands
/// somewhere new.
class _SequentialRootSource implements ProjectRootSource {
  _SequentialRootSource(this.paths);
  final List<String> paths;
  int _index = 0;

  @override
  Future<String?> pickDirectory() async {
    final path = paths[_index.clamp(0, paths.length - 1)];
    if (_index < paths.length - 1) _index++;
    return path;
  }
}

/// A controllable double for opencode's HTTP/SSE API — records every call
/// and lets a test drive the event stream directly (`emit`), the same way
/// the old tests drove a `Completer` to control the local agent loop's
/// timing by hand.
class _FakeOpencodeClient implements OpencodeClient {
  final _events = StreamController<OpencodeEvent>.broadcast();
  final createSessionCalls = <String>[]; // projectRoot per call
  final sendMessageCalls = <(String sessionId, String text)>[];
  final respondCalls = <(String permissionId, ToolApprovalDecision decision)>[];
  final abortCalls = <String>[]; // sessionId per call

  int _nextSessionId = 1;
  String? lastCreatedSessionId;

  void emit(OpencodeEvent event) => _events.add(event);

  @override
  Future<String> createSession(String projectRoot) async {
    createSessionCalls.add(projectRoot);
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
  }) async {
    sendMessageCalls.add((sessionId, text));
  }

  @override
  Future<void> respondToPermission({
    required String projectRoot,
    required String permissionId,
    required ToolApprovalDecision decision,
  }) async {
    respondCalls.add((permissionId, decision));
  }

  @override
  Future<void> abort({
    required String projectRoot,
    required String sessionId,
  }) async {
    abortCalls.add(sessionId);
  }

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

  int ensureRunningCalls = 0;

  /// What [isInstalled] reports; [install] flips it to true when it completes.
  bool installed = true;
  bool installable = true;
  int installCalls = 0;
  Object? installError;

  @override
  Future<void> ensureRunning({required ModelInfo model}) async {
    ensureRunningCalls++;
  }

  @override
  Future<bool> isInstalled() async => installed;

  @override
  bool get canInstall => installable;

  @override
  int get installBytes => 98000000;

  @override
  Stream<CodeEngineProgress> install() async* {
    installCalls++;
    yield const CodeEngineProgress('Downloading opencode…', fraction: 0.5);
    if (installError != null) throw installError!;
    installed = true;
    yield const CodeEngineProgress('Installed opencode.', fraction: 1);
  }

  @override
  Future<void> stop() async {}
}

/// A tool-part event, as opencode's `/event` stream would send it — see
/// `opencode_client.dart`'s `OpencodePartEvent` doc comment for why this
/// stays a raw map instead of a typed model.
OpencodePartEvent _toolPart(
  String sessionId,
  String callId,
  String tool, {
  required String status,
  Map<String, dynamic> input = const {},
  String? output,
  String? error,
}) => OpencodePartEvent(sessionId, {
  'id': 'prt_$callId',
  'sessionID': sessionId,
  'messageID': 'msg_1',
  'type': 'tool',
  'callID': callId,
  'tool': tool,
  'state': {
    'status': status,
    'input': input,
    'output': ?output,
    'error': ?error,
  },
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

Future<(CodeAgentController, _FakeOpencodeClient, Directory)> _buildReady({
  String? root,
}) async {
  final tempRoot = root == null
      ? await Directory.systemTemp.createTemp('code_agent_test')
      : null;
  final api = _FakeApi([_alpha]);
  final pool = ModelPool(api: api, downloadManager: const _NoDownloads());
  await pool.refresh();
  final client = _FakeOpencodeClient();
  final controller = CodeAgentController(
    pool: pool,
    projectRootSource: _FakeRootSource(root ?? tempRoot!.path),
    engine: _FakeCodeEngine(client),
  )..start();
  await controller.pickProjectRoot();
  controller.selectModel('alpha');
  return (controller, client, tempRoot ?? Directory(root!));
}

/// Every turn below starts with `send()`, then waits here before driving the
/// fake client's event stream — `send()`'s own async chain (ensureRunning →
/// event subscription → createSession → sendMessageAsync) all resolves on
/// fakes with no real I/O, so a zero-duration delay is enough to let it
/// reach the point of awaiting the turn completer.
Future<void> _letSendReachTheCompleter() => Future<void>.delayed(Duration.zero);

void main() {
  test('canSend needs both a project root and a model', () async {
    final api = _FakeApi([_alpha]);
    final pool = ModelPool(api: api, downloadManager: const _NoDownloads());
    await pool.refresh();
    final tempRoot = await Directory.systemTemp.createTemp('code_agent_test');
    addTearDown(() => tempRoot.delete(recursive: true));

    final controller = CodeAgentController(
      pool: pool,
      projectRootSource: _FakeRootSource(tempRoot.path),
      engine: _FakeCodeEngine(_FakeOpencodeClient()),
    )..start();
    expect(controller.canSend, isFalse);

    await controller.pickProjectRoot();
    expect(controller.canSend, isFalse, reason: 'no model chosen yet');

    controller.selectModel('alpha');
    expect(controller.canSend, isTrue);
  });

  test('availableModels lists on-device models and server models with managed weights', () async {
    const onDevice = ModelInfo(
      id: 'on-device',
      name: 'On-device',
      gguf: 'hf://x/y/z.gguf',
    );
    const serverWeights = ModelInfo(
      id: 'server-weights',
      name: 'Server weights',
      hasServerWeights: true,
    );
    const byoEndpoint = ModelInfo(
      id: 'byo-endpoint',
      name: 'BYO endpoint',
      externalEndpoint: 'http://localhost:8010',
    );
    const serverOnly = ModelInfo(id: 'server-only', name: 'Server-only');
    final api = _FakeApi([onDevice, serverWeights, byoEndpoint, serverOnly]);
    // Both need to report as downloaded for this to test the filter this
    // controller applies rather than ModelPool's own download gate —
    // serverOnly via _FakeApi.getServerModelCacheStatus (cached: true),
    // onDevice via this manager.
    final pool = ModelPool(api: api, downloadManager: const _FakeDownloads());
    await pool.refresh();
    final tempRoot = await Directory.systemTemp.createTemp('code_agent_test');
    addTearDown(() => tempRoot.delete(recursive: true));

    final controller = CodeAgentController(
      pool: pool,
      projectRootSource: _FakeRootSource(tempRoot.path),
      engine: _FakeCodeEngine(_FakeOpencodeClient()),
    )..start();

    // The bundled always-on on-device fallback model is also GGUF-declaring
    // and legitimately belongs here too — assert on membership, not an exact
    // list, so this doesn't couple to that roster detail.
    final ids = controller.availableModels.map((m) => m.id).toSet();
    expect(ids, contains('on-device'));
    expect(ids, contains('server-weights'));
    expect(ids, isNot(contains('byo-endpoint')));
    expect(ids, isNot(contains('server-only')));
  });

  test(
    'a tool-call turn followed by a final answer updates the transcript in order',
    () async {
      final (controller, client, root) = await _buildReady();
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

      expect(controller.running, isFalse);
      expect(controller.error, isNull);
      expect(controller.transcript, hasLength(3));
      expect(controller.transcript[0], isA<UserTranscriptEntry>());
      final toolEntry = controller.transcript[1] as ToolCallTranscriptEntry;
      expect(toolEntry.name, 'list');
      expect(toolEntry.status, ToolCallStatus.done);
      expect(toolEntry.resultText, 'a.txt');
      final answer = controller.transcript[2] as AssistantTextTranscriptEntry;
      expect(answer.text, 'Found some files.');
    },
  );

  test(
    'a gated tool call waits for approval before opencode is told to proceed',
    () async {
      final (controller, client, root) = await _buildReady();
      addTearDown(() => root.delete(recursive: true));

      ToolApprovalRequest? request;
      controller.approvalRequests.listen((r) => request = r);

      final run = controller.send('write a file');
      await _letSendReachTheCompleter();
      final sessionId = client.lastCreatedSessionId!;

      client.emit(
        _toolPart(
          sessionId,
          'call_1',
          'write',
          status: 'pending',
          input: {'path': 'out.txt'},
        ),
      );
      client.emit(OpencodePermissionEvent(sessionId, 'per_1', 'call_1'));
      await _letSendReachTheCompleter();

      expect(request, isNotNull);
      expect(request!.toolName, 'write');
      final toolEntry = controller.transcript
          .whereType<ToolCallTranscriptEntry>()
          .single;
      expect(toolEntry.status, ToolCallStatus.awaitingApproval);

      request!.completer.complete(ToolApprovalDecision.allowOnce);
      await _letSendReachTheCompleter();
      expect(client.respondCalls, [('per_1', ToolApprovalDecision.allowOnce)]);

      client.emit(
        _toolPart(
          sessionId,
          'call_1',
          'write',
          status: 'completed',
          output: 'wrote it',
        ),
      );
      client.emit(_textPart(sessionId, 'prt_2', 'Done.'));
      client.emit(OpencodeSessionIdleEvent(sessionId));
      await run;

      expect(toolEntry.status, ToolCallStatus.done);
    },
  );

  test(
    'denying a gated call marks it denied without waiting for opencode, and the model still '
    'replies',
    () async {
      final (controller, client, root) = await _buildReady();
      addTearDown(() => root.delete(recursive: true));

      ToolApprovalRequest? request;
      controller.approvalRequests.listen((r) => request = r);

      final run = controller.send('write a file');
      await _letSendReachTheCompleter();
      final sessionId = client.lastCreatedSessionId!;

      client.emit(_toolPart(sessionId, 'call_1', 'write', status: 'pending'));
      client.emit(OpencodePermissionEvent(sessionId, 'per_1', 'call_1'));
      await _letSendReachTheCompleter();

      request!.completer.complete(ToolApprovalDecision.deny);
      await _letSendReachTheCompleter();

      expect(client.respondCalls, [('per_1', ToolApprovalDecision.deny)]);
      final toolEntry = controller.transcript
          .whereType<ToolCallTranscriptEntry>()
          .single;
      expect(toolEntry.status, ToolCallStatus.denied);

      client.emit(_textPart(sessionId, 'prt_2', 'Okay, skipping that.'));
      client.emit(OpencodeSessionIdleEvent(sessionId));
      await run;

      final answer = controller.transcript
          .whereType<AssistantTextTranscriptEntry>()
          .single;
      expect(answer.text, 'Okay, skipping that.');
    },
  );

  test(
    'choosing "allow for session" sends opencode an "always" reply',
    () async {
      final (controller, client, root) = await _buildReady();
      addTearDown(() => root.delete(recursive: true));

      ToolApprovalRequest? request;
      controller.approvalRequests.listen((r) => request = r);

      final run = controller.send('write two files');
      await _letSendReachTheCompleter();
      final sessionId = client.lastCreatedSessionId!;

      client.emit(_toolPart(sessionId, 'call_1', 'write', status: 'pending'));
      client.emit(OpencodePermissionEvent(sessionId, 'per_1', 'call_1'));
      await _letSendReachTheCompleter();
      request!.completer.complete(ToolApprovalDecision.allowForSession);
      await _letSendReachTheCompleter();

      expect(client.respondCalls, [
        ('per_1', ToolApprovalDecision.allowForSession),
      ]);

      client.emit(
        _toolPart(
          sessionId,
          'call_1',
          'write',
          status: 'completed',
          output: 'ok',
        ),
      );
      client.emit(OpencodeSessionIdleEvent(sessionId));
      await run;
    },
  );

  test(
    'a failing tool does not sink the run — the model still gets a chance to answer',
    () async {
      final (controller, client, root) = await _buildReady();
      addTearDown(() => root.delete(recursive: true));

      final run = controller.send('read missing.txt');
      await _letSendReachTheCompleter();
      final sessionId = client.lastCreatedSessionId!;

      client.emit(
        _toolPart(
          sessionId,
          'call_1',
          'read',
          status: 'error',
          error: 'File not found: missing.txt',
        ),
      );
      client.emit(_textPart(sessionId, 'prt_1', 'That file does not exist.'));
      client.emit(OpencodeSessionIdleEvent(sessionId));
      await run;

      expect(controller.error, isNull);
      final toolEntry = controller.transcript
          .whereType<ToolCallTranscriptEntry>()
          .single;
      expect(toolEntry.status, ToolCallStatus.error);
      final answer = controller.transcript
          .whereType<AssistantTextTranscriptEntry>()
          .single;
      expect(answer.text, 'That file does not exist.');
    },
  );

  test('a session.error event ends the run with that message', () async {
    final (controller, client, root) = await _buildReady();
    addTearDown(() => root.delete(recursive: true));

    final run = controller.send('hello');
    await _letSendReachTheCompleter();
    final sessionId = client.lastCreatedSessionId!;

    client.emit(OpencodeSessionErrorEvent(sessionId, 'Cannot connect to API'));
    await run;

    expect(controller.running, isFalse);
    expect(controller.error, 'Cannot connect to API');
  });

  test(
    'stop() ends the run, aborts the opencode session, and discards a late-arriving reply',
    () async {
      final (controller, client, root) = await _buildReady();
      addTearDown(() => root.delete(recursive: true));

      final run = controller.send('hang on');
      await _letSendReachTheCompleter();
      final sessionId = client.lastCreatedSessionId!;
      expect(controller.running, isTrue);

      controller.stop();
      expect(controller.running, isFalse);
      expect(client.abortCalls, [sessionId]);
      await run;

      // Even if the session keeps streaming for a moment after abort, it must
      // not land in the transcript.
      client.emit(_textPart(sessionId, 'prt_1', 'too late'));
      client.emit(OpencodeSessionIdleEvent(sessionId));
      await _letSendReachTheCompleter();

      expect(
        controller.transcript.whereType<AssistantTextTranscriptEntry>(),
        isEmpty,
      );
    },
  );

  test(
    'stop() denies a pending approval so the wait does not hang forever',
    () async {
      final (controller, client, root) = await _buildReady();
      addTearDown(() => root.delete(recursive: true));

      final run = controller.send('write a file');
      await _letSendReachTheCompleter();
      final sessionId = client.lastCreatedSessionId!;

      client.emit(_toolPart(sessionId, 'call_1', 'write', status: 'pending'));
      client.emit(OpencodePermissionEvent(sessionId, 'per_1', 'call_1'));
      await _letSendReachTheCompleter();
      expect(controller.running, isTrue);

      controller.stop();
      // The run's own future must complete promptly rather than hang on the
      // approval it will now never receive an answer for from a UI.
      await run.timeout(const Duration(seconds: 5));

      expect(client.respondCalls, [('per_1', ToolApprovalDecision.deny)]);
      final toolEntry = controller.transcript
          .whereType<ToolCallTranscriptEntry>()
          .single;
      expect(toolEntry.status, ToolCallStatus.denied);
    },
  );

  group('history', () {
    test(
      'a second send continues the same opencode session — one conversation, not two',
      () async {
        final (controller, client, root) = await _buildReady();
        addTearDown(() => root.delete(recursive: true));

        final run1 = controller.send('hello');
        await _letSendReachTheCompleter();
        final sessionId = client.lastCreatedSessionId!;
        client.emit(_textPart(sessionId, 'prt_1', 'first reply'));
        client.emit(OpencodeSessionIdleEvent(sessionId));
        await run1;

        final run2 = controller.send('again');
        await _letSendReachTheCompleter();
        client.emit(_textPart(sessionId, 'prt_2', 'second reply'));
        client.emit(OpencodeSessionIdleEvent(sessionId));
        await run2;

        expect(
          client.createSessionCalls,
          hasLength(1),
          reason: 'only one opencode session created',
        );
        expect(
          controller.sessions.where((s) => s.transcript.isNotEmpty),
          hasLength(1),
        );
        expect(
          controller.transcript,
          hasLength(4),
        ); // user, assistant, user, assistant
      },
    );

    test(
      'picking a new project root starts a fresh session, keeping the old one in history',
      () async {
        final api = _FakeApi([_alpha]);
        final pool = ModelPool(api: api, downloadManager: const _NoDownloads());
        await pool.refresh();
        final rootA = await Directory.systemTemp.createTemp(
          'code_agent_test_a',
        );
        final rootB = await Directory.systemTemp.createTemp(
          'code_agent_test_b',
        );
        addTearDown(() => rootA.delete(recursive: true));
        addTearDown(() => rootB.delete(recursive: true));
        final client = _FakeOpencodeClient();

        final controller = CodeAgentController(
          pool: pool,
          projectRootSource: _SequentialRootSource([rootA.path, rootB.path]),
          engine: _FakeCodeEngine(client),
        )..start();
        await controller.pickProjectRoot();
        controller.selectModel('alpha');

        final runA = controller.send('in project A');
        await _letSendReachTheCompleter();
        var sid = client.lastCreatedSessionId!;
        client.emit(OpencodeSessionIdleEvent(sid));
        await runA;

        await controller.pickProjectRoot(); // now lands on rootB
        expect(controller.transcript, isEmpty);
        final runB = controller.send('in project B');
        await _letSendReachTheCompleter();
        sid = client.lastCreatedSessionId!;
        client.emit(OpencodeSessionIdleEvent(sid));
        await runB;

        final answered = controller.sessions
            .where((s) => s.transcript.isNotEmpty)
            .toList();
        expect(answered, hasLength(2));
        expect(answered.map((s) => s.projectRoot), [rootB.path, rootA.path]);
      },
    );

    test('selecting a different model starts a fresh session', () async {
      final api = _FakeApi([_alpha, const ModelInfo(id: 'beta', name: 'Beta')]);
      final pool = ModelPool(api: api, downloadManager: const _NoDownloads());
      await pool.refresh();
      final root = await Directory.systemTemp.createTemp('code_agent_test');
      addTearDown(() => root.delete(recursive: true));
      final client = _FakeOpencodeClient();

      final controller = CodeAgentController(
        pool: pool,
        projectRootSource: _FakeRootSource(root.path),
        engine: _FakeCodeEngine(client),
      )..start();
      await controller.pickProjectRoot();
      controller.selectModel('alpha');

      final runAlpha = controller.send('with alpha');
      await _letSendReachTheCompleter();
      client.emit(OpencodeSessionIdleEvent(client.lastCreatedSessionId!));
      await runAlpha;

      controller.selectModel('beta');
      expect(controller.transcript, isEmpty);
      final runBeta = controller.send('with beta');
      await _letSendReachTheCompleter();
      client.emit(OpencodeSessionIdleEvent(client.lastCreatedSessionId!));
      await runBeta;

      expect(
        controller.sessions.where((s) => s.transcript.isNotEmpty),
        hasLength(2),
      );
    });

    test(
      'newSession reuses the empty slot instead of piling up duplicates',
      () async {
        final (controller, _, root) = await _buildReady();
        addTearDown(() => root.delete(recursive: true));
        final before = controller.sessions.length;

        controller.newSession();
        controller.newSession();

        expect(controller.sessions.length, before);
        expect(controller.transcript, isEmpty);
      },
    );

    test(
      'deleteSession removes a conversation and falls back to another one',
      () async {
        final (controller, client, root) = await _buildReady();
        addTearDown(() => root.delete(recursive: true));

        final run1 = controller.send('hello');
        await _letSendReachTheCompleter();
        client.emit(OpencodeSessionIdleEvent(client.lastCreatedSessionId!));
        await run1;

        controller.newSession();
        final run2 = controller.send('a different conversation');
        await _letSendReachTheCompleter();
        client.emit(OpencodeSessionIdleEvent(client.lastCreatedSessionId!));
        await run2;

        controller.deleteSession(
          0,
        ); // the active ("a different conversation") one
        final remaining = controller.sessions
            .where((s) => s.transcript.isNotEmpty)
            .toList();
        expect(remaining, hasLength(1));
        expect(
          (remaining.single.transcript.first as UserTranscriptEntry).text,
          'hello',
        );
      },
    );

    test(
      'a conversation persists through InMemoryCodeSessionStore and reloads into a fresh '
      'controller, continuing the same opencode session rather than starting a new one',
      () async {
        final sharedStore = InMemoryCodeSessionStore();
        final api = _FakeApi([_alpha]);
        final pool = ModelPool(api: api, downloadManager: const _NoDownloads());
        await pool.refresh();
        final root = await Directory.systemTemp.createTemp('code_agent_test');
        addTearDown(() => root.delete(recursive: true));
        final client = _FakeOpencodeClient();

        final first = CodeAgentController(
          pool: pool,
          projectRootSource: _FakeRootSource(root.path),
          store: sharedStore,
          engine: _FakeCodeEngine(client),
        )..start();
        await first.pickProjectRoot();
        first.selectModel('alpha');
        final run1 = first.send('list the files');
        await _letSendReachTheCompleter();
        final sessionId = client.lastCreatedSessionId!;
        client.emit(_textPart(sessionId, 'prt_1', 'Found some files.'));
        client.emit(OpencodeSessionIdleEvent(sessionId));
        await run1;

        final second = CodeAgentController(
          pool: pool,
          projectRootSource: _FakeRootSource(root.path),
          store: sharedStore,
          engine: _FakeCodeEngine(client),
        )..start();
        await Future<void>.delayed(
          Duration.zero,
        ); // let the stored history load

        final restored = second.sessions.firstWhere(
          (s) => s.transcript.isNotEmpty,
        );
        expect(restored.title, 'list the files');
        expect(restored.opencodeSessionId, sessionId);

        await second.pickProjectRoot();
        second.selectModel('alpha');
        second.selectSession(second.sessions.indexOf(restored));
        final run2 = second.send('and now?');
        await _letSendReachTheCompleter();
        client.emit(_textPart(sessionId, 'prt_2', 'A follow-up answer.'));
        client.emit(OpencodeSessionIdleEvent(sessionId));
        await run2;

        expect(
          client.createSessionCalls,
          hasLength(1),
          reason: 'reused the restored session',
        );
        expect(client.sendMessageCalls.last.$1, sessionId);
        expect(
          restored.transcript
              .whereType<AssistantTextTranscriptEntry>()
              .last
              .text,
          'A follow-up answer.',
        );
      },
    );
  });
}
