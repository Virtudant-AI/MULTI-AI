import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api_client.dart' show ModelInfo;
import '../../model_pool.dart';
import 'code_engine.dart';
import 'code_engine_installer.dart' show CodeEngineProgress;
import 'code_session_store.dart';
import 'opencode_client.dart';
import 'project_root_source.dart';
import 'tool_approval.dart';

/// Where one tool call is in its lifecycle — see [ToolCallTranscriptEntry].
enum ToolCallStatus { running, awaitingApproval, done, error, denied }

/// One row in the Code tab's transcript.
sealed class CodeTranscriptEntry {
  Map<String, dynamic> toJson();
}

class UserTranscriptEntry extends CodeTranscriptEntry {
  UserTranscriptEntry(this.text);
  final String text;

  @override
  Map<String, dynamic> toJson() => {'type': 'user', 'text': text};
}

/// Mutable `text` (not `final`) because opencode streams a part's text as
/// repeated whole-value updates for the same part id, not deltas — see
/// `CodeAgentController._applyTextPart`. [partId] identifies which opencode
/// message part this row mirrors so later updates land on it instead of
/// appending a duplicate row; it's live-session-only bookkeeping, not
/// persisted (a reloaded session never receives more updates for it).
class AssistantTextTranscriptEntry extends CodeTranscriptEntry {
  AssistantTextTranscriptEntry(this.text, {this.partId});
  String text;
  String? partId;

  @override
  Map<String, dynamic> toJson() => {'type': 'assistant', 'text': text};
}

/// A tool call and its eventual result. Mutable status/result fields — mirrors
/// `CouncilStep` in orchestration_controller.dart — so the same object updates
/// in place as approval, execution, and the result each land, rather than the
/// transcript needing a rebuilt list on every step. [id] is opencode's
/// `callID` for the tool part, which is how incoming part/permission events
/// find their way back to this row.
class ToolCallTranscriptEntry extends CodeTranscriptEntry {
  ToolCallTranscriptEntry({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  final String id;
  final String name;
  String argumentsJson;
  ToolCallStatus status = ToolCallStatus.running;
  String resultText = '';

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool',
        'id': id,
        'name': name,
        'argumentsJson': argumentsJson,
        'status': status.name,
        'resultText': resultText,
      };
}

/// Rebuilds one transcript row from disk. Null for a `type` this build
/// doesn't know — a history file written by a newer version shouldn't make
/// the whole session fail to load, mirroring `_attachmentFromJson` in
/// `chat_store.dart`.
///
/// A tool call loaded as `running`/`awaitingApproval` was interrupted mid-run
/// (the app closed before it resolved) and can never resume — surfaced as
/// failed rather than a permanently spinning row.
CodeTranscriptEntry? codeTranscriptEntryFromJson(Map<String, dynamic> json) {
  switch (json['type'] as String?) {
    case 'user':
      return UserTranscriptEntry(json['text'] as String? ?? '');
    case 'assistant':
      return AssistantTextTranscriptEntry(json['text'] as String? ?? '');
    case 'tool':
      final entry = ToolCallTranscriptEntry(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        argumentsJson: json['argumentsJson'] as String? ?? '',
      );
      final status = ToolCallStatus.values
          .firstWhere((s) => s.name == json['status'], orElse: () => ToolCallStatus.error);
      entry.status =
          status == ToolCallStatus.running || status == ToolCallStatus.awaitingApproval
              ? ToolCallStatus.error
              : status;
      entry.resultText = json['resultText'] as String? ?? '';
      return entry;
    default:
      return null;
  }
}

/// One gated tool call awaiting a decision — [permissionId] is what
/// `respondToPermission` needs, [entry] is the transcript row to update once
/// the decision is known, and [completer] is what the pane's approval
/// dialog resolves — kept here so [CodeAgentController.stop] can complete it
/// directly (with a deny) rather than leave `_awaitApprovalDecision`
/// awaiting it forever.
class _PendingApproval {
  _PendingApproval(this.permissionId, this.entry, this.completer);
  final String permissionId;
  final ToolCallTranscriptEntry entry;
  final Completer<ToolApprovalDecision> completer;
}

/// Drives the Code tab's agent loop by proxying to a real `opencode serve`
/// process (see `code_engine.dart`) over HTTP/SSE, rather than running a
/// local agent loop itself. Keeps every past conversation as a [CodeSession]
/// so the sidebar can show a history of them, the same way `ChatController`
/// keeps past chats and `OrchestrationController` keeps past council runs.
///
/// Shaped like `OrchestrationController` on purpose — a `ChangeNotifier`, a
/// `_runGeneration` guard so a result from a run [stop] already ended can't
/// land, and every state change wrapped in `notifyListeners()`. Unlike the
/// Council (fresh per question), a session's underlying opencode session
/// persists across [send] calls: the Code tab is a continuing conversation,
/// the same way Claude Code's own session is, not a series of one-shot
/// questions.
///
/// `send()` doesn't run the turn itself — it starts/reuses the backing
/// processes, creates an opencode session if needed, hands the message to
/// opencode (`prompt_async`, which returns immediately), and then awaits a
/// completer that a shared, long-lived subscription to opencode's event
/// stream (`_onEvent`) resolves once a `session.idle`/`session.error` event
/// arrives for that session — see `_ensureEventSubscription`.
class CodeAgentController extends ChangeNotifier {
  CodeAgentController({
    required this.pool,
    ProjectRootSource? projectRootSource,
    CodeSessionStore? store,
    CodeEngine? engine,
  })  : _rootSource = projectRootSource ?? DefaultProjectRootSource(),
        _store = store ?? FileCodeSessionStore(),
        _engine = engine ?? LocalCodeEngine();

  final ModelPool pool;
  final ProjectRootSource _rootSource;
  final CodeSessionStore _store;
  final CodeEngine _engine;

  String? _projectRoot;
  String? get projectRoot => _projectRoot;

  ModelInfo? _selectedModel;
  ModelInfo? get selectedModel => _selectedModel;

  final _sessions = <CodeSession>[CodeSession()];
  int _activeSession = 0;

  List<CodeSession> get sessions => List.unmodifiable(_sessions);
  int get activeSessionIndex => _activeSession;
  CodeSession get session => _sessions[_activeSession];

  List<CodeTranscriptEntry> get transcript => List.unmodifiable(session.transcript);

  bool _running = false;
  bool get running => _running;

  int _runGeneration = 0;

  String? get error => session.error;

  final _approvals = StreamController<ToolApprovalRequest>.broadcast();
  Stream<ToolApprovalRequest> get approvalRequests => _approvals.stream;

  /// The gated call currently awaiting a decision, if any — [stop] rejects
  /// it (both locally and on opencode's server) so a run stopped mid-approval
  /// doesn't leave opencode's session hanging.
  _PendingApproval? _pendingApproval;

  /// Resolved by [_onEvent] when a `session.idle`/`session.error` event
  /// arrives for the given opencode session id — this is what makes an
  /// `await send(...)` call not return until the whole turn (including any
  /// tool calls) has actually finished, matching this controller's shape
  /// before opencode owned the loop.
  final _turnCompleters = <String, Completer<void>>{};

  /// Which [_runGeneration] each opencode session id currently belongs to —
  /// lets [_onEvent] ignore an event for a run [stop] already ended, the
  /// same guard the old local agent loop applied via `generation !=
  /// _runGeneration` checks in its own hook callbacks.
  final _sessionGeneration = <String, int>{};

  StreamSubscription<OpencodeEvent>? _eventSub;
  String? _eventSubProjectRoot;

  /// Downloaded models the Code tab can run: on-device (GGUF) ones, plus
  /// server-side models whose weights the backend manages, reached through its
  /// OpenAI-compatible route. A BYO external endpoint (no managed weights) is
  /// excluded — nothing here knows it speaks OpenAI. See the README's "Code
  /// tab" section.
  List<ModelInfo> get availableModels => pool.downloaded
      .where((m) =>
          ModelPool.localSourceOf(m) != null ||
          (m.hasServerWeights && m.externalEndpoint == null))
      .toList();

  bool get canSend =>
      !_running && _projectRoot != null && _selectedModel != null && _engineReady != false;

  // ----------------------------------------------------------- engine install

  /// Whether `llama-server` and `opencode` are available: null until the first
  /// check finishes (sending isn't blocked on that), then true or false. The
  /// Code tab shows its install card while this is false.
  bool? _engineReady;
  bool? get engineReady => _engineReady;

  /// Whether this platform can install them for the user at all.
  bool get engineCanInstall => _engine.canInstall;
  int get engineInstallBytes => _engine.installBytes;

  bool _engineInstalling = false;
  bool get engineInstalling => _engineInstalling;

  CodeEngineProgress? _engineProgress;
  CodeEngineProgress? get engineProgress => _engineProgress;

  String? _engineInstallError;
  String? get engineInstallError => _engineInstallError;

  /// Re-checks whether the engine is installed. Called at start and after an
  /// install; cheap enough to call again whenever the user might have installed
  /// the programs themselves.
  Future<void> refreshEngine() async {
    final ready = await _engine.isInstalled();
    if (ready == _engineReady) return;
    _engineReady = ready;
    notifyListeners();
  }

  /// Downloads and installs the engine, surfacing progress through
  /// [engineProgress] and any failure through [engineInstallError].
  Future<void> installEngine() async {
    if (_engineInstalling) return;
    _engineInstalling = true;
    _engineInstallError = null;
    _engineProgress = null;
    notifyListeners();
    try {
      await for (final progress in _engine.install()) {
        _engineProgress = progress;
        notifyListeners();
      }
    } catch (e) {
      _engineInstallError = e is StateError ? e.message : e.toString();
    } finally {
      _engineInstalling = false;
      _engineProgress = null;
      notifyListeners();
    }
    await refreshEngine();
  }

  void start() {
    pool.addListener(_onPoolChanged);
    _onPoolChanged();
    unawaited(_loadStoredSessions());
    unawaited(refreshEngine());
  }

  Future<void> _loadStoredSessions() async {
    final stored = await _store.load();
    if (stored.isEmpty) return;
    // Keep the fresh empty session on top and resume with history below it.
    _sessions.addAll(stored);
    notifyListeners();
  }

  /// Drops the selected model if it's no longer downloaded — left alone
  /// mid-run so a delete on the Models tab can't yank a model out from under
  /// an in-flight turn, matching `OrchestrationController._onPoolChanged`.
  void _onPoolChanged() {
    if (!_running && pool.ready) {
      final selected = _selectedModel;
      if (selected != null && !pool.downloadedIds.contains(selected.id)) {
        _selectedModel = null;
      }
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- sessions

  void newSession() {
    // Reuse an existing empty session (they're hidden from the sidebar, so
    // stacking up duplicates would leak invisible entries).
    final existing = _sessions.indexWhere((s) => s.transcript.isEmpty);
    _setActiveSession(existing >= 0 ? existing : null);
  }

  void selectSession(int index) => _setActiveSession(index);

  void deleteSession(int index) {
    _sessions.removeAt(index);
    if (_sessions.isEmpty) _sessions.add(CodeSession());
    if (_activeSession >= _sessions.length) {
      _activeSession = _sessions.length - 1;
    } else if (index < _activeSession) {
      _activeSession -= 1;
    }
    notifyListeners();
    _store.save(_sessions);
  }

  /// Switches the active session to [index], or inserts a fresh empty one at
  /// the top when null.
  void _setActiveSession(int? index) {
    if (index == null) {
      _sessions.insert(0, CodeSession());
      _activeSession = 0;
    } else {
      _activeSession = index;
    }
    notifyListeners();
  }

  Future<void> pickProjectRoot() async {
    if (_running) return;
    final path = await _rootSource.pickDirectory();
    if (path == null) return;
    _projectRoot = path;
    // A different project starts a new conversation.
    newSession();
  }

  void selectModel(String id) {
    if (_running) return;
    final model = pool.models.where((m) => m.id == id).firstOrNull;
    if (model == null || model.id == _selectedModel?.id) return;
    _selectedModel = model;
    // A different model starts a new conversation.
    newSession();
  }

  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (!canSend || trimmed.isEmpty) return;

    final generation = ++_runGeneration;
    _running = true;
    final session = this.session;
    final projectRoot = _projectRoot!;
    final model = _selectedModel!;
    session.error = null;
    session.title ??= trimmed;
    session.projectRoot = projectRoot;
    session.modelId = model.id;
    session.modelName = model.name;
    session.transcript.add(UserTranscriptEntry(trimmed));
    notifyListeners();
    _store.save(_sessions);

    try {
      await _engine.ensureRunning(model: model);
      if (generation != _runGeneration) return; // stop() fired while starting up

      await _ensureEventSubscription(projectRoot);
      if (generation != _runGeneration) return;

      var sessionId = session.opencodeSessionId;
      if (sessionId == null) {
        sessionId = await _engine.client.createSession(projectRoot);
        session.opencodeSessionId = sessionId;
      }
      if (generation != _runGeneration) return;

      // Tags this session id with the run it belongs to for the rest of this
      // turn, so `_onEvent` can tell a still-current event apart from one
      // arriving after `stop()` (or a new `send()`) already moved on — see
      // `_onEvent`'s doc comment.
      _sessionGeneration[sessionId] = generation;

      final completer = Completer<void>();
      _turnCompleters[sessionId] = completer;

      await _engine.client.sendMessageAsync(
        projectRoot: projectRoot,
        sessionId: sessionId,
        providerId: _engine.providerIdFor(model),
        modelId: _engine.modelIdFor(model),
        text: trimmed,
      );
      if (generation != _runGeneration) return;

      await completer.future;
    } catch (e) {
      if (generation == _runGeneration) session.error = e.toString();
    } finally {
      if (generation == _runGeneration) {
        _running = false;
        notifyListeners();
      }
      _store.save(_sessions);
    }
  }

  /// Ends the run and discards whatever it was doing. Mirrors
  /// `OrchestrationController.stop()`: bump the generation guard so a result
  /// that lands afterward is ignored, then abort whatever's actually in
  /// flight — opencode's own turn, via its permission-reject and (best
  /// effort) an aborted wait, rather than a model generation this controller
  /// no longer drives directly.
  void stop() {
    if (!_running) return;
    _runGeneration++;

    final pending = _pendingApproval;
    if (pending != null) {
      _pendingApproval = null;
      pending.entry.status = ToolCallStatus.denied;
      // Completing this (rather than leaving it for the pane's dialog, which
      // may never resolve if the user never sees it again) is what lets
      // `_awaitApprovalDecision` actually finish instead of awaiting forever
      // — it checks `_pendingApproval` before acting, so this doesn't cause
      // a double reply below.
      if (!pending.completer.isCompleted) {
        pending.completer.complete(ToolApprovalDecision.deny);
      }
      final root = _projectRoot;
      if (root != null) {
        unawaited(
          _engine.client
              .respondToPermission(
                projectRoot: root,
                permissionId: pending.permissionId,
                decision: ToolApprovalDecision.deny,
              )
              .catchError((_) {}),
        );
      }
    }

    final sessionId = session.opencodeSessionId;
    final root = _projectRoot;
    if (sessionId != null && root != null) {
      unawaited(_engine.client.abort(projectRoot: root, sessionId: sessionId).catchError((_) {}));
    }
    _turnCompleters.remove(sessionId)?.complete();

    _running = false;
    notifyListeners();
    _store.save(_sessions);
  }

  // --------------------------------------------------------------- opencode

  /// Opens (or reopens, if [projectRoot] changed) the shared event
  /// subscription driving [_onEvent] for the lifetime of the app — opencode
  /// only delivers session/message/permission events on `/event` when the
  /// request's `directory` query param matches the session's (confirmed
  /// empirically against a running server, not documented), so this has to
  /// track whichever project root is currently in use.
  Future<void> _ensureEventSubscription(String projectRoot) async {
    if (_eventSubProjectRoot == projectRoot && _eventSub != null) return;
    await _eventSub?.cancel();
    _eventSubProjectRoot = projectRoot;
    _eventSub = _engine.client.events(projectRoot).listen(_onEvent);
  }

  CodeSession? _sessionForOpencodeId(String opencodeSessionId) =>
      _sessions.where((s) => s.opencodeSessionId == opencodeSessionId).lastOrNull;

  /// Applies one event, unless it belongs to a run [stop] already ended (or
  /// a session this controller never started, e.g. a leftover from a
  /// previous app run still on the shared SSE connection) — see
  /// [_sessionGeneration]'s doc comment. This is what makes "stop() ends the
  /// run and discards a late-arriving reply" true even though completion now
  /// arrives asynchronously over HTTP rather than as a direct call result.
  void _onEvent(OpencodeEvent event) {
    if (_sessionGeneration[event.sessionId] != _runGeneration) return;
    final session = _sessionForOpencodeId(event.sessionId);
    if (session == null) return;

    switch (event) {
      case OpencodePartEvent(:final part):
        _applyPart(session, part);
      case OpencodePermissionEvent():
        _handlePermissionAsked(session, event);
      case OpencodeSessionIdleEvent():
        _completeTurn(event.sessionId);
      case OpencodeSessionErrorEvent(:final message):
        session.error = message;
        _completeTurn(event.sessionId);
    }
    _store.save(_sessions);
  }

  void _applyPart(CodeSession session, Map<String, dynamic> part) {
    switch (part['type'] as String?) {
      case 'text':
        _applyTextPart(session, part);
      case 'tool':
        _applyToolPart(session, part);
    }
  }

  void _applyTextPart(CodeSession session, Map<String, dynamic> part) {
    final partId = part['id'] as String?;
    final text = part['text'] as String?;
    if (partId == null || text == null || text.trim().isEmpty) return;

    final entry = session.transcript
        .whereType<AssistantTextTranscriptEntry>()
        .where((e) => e.partId == partId)
        .lastOrNull;
    if (entry != null) {
      entry.text = text.trim();
    } else {
      session.transcript.add(AssistantTextTranscriptEntry(text.trim(), partId: partId));
    }
    notifyListeners();
  }

  void _applyToolPart(CodeSession session, Map<String, dynamic> part) {
    final callId = part['callID'] as String?;
    final toolName = part['tool'] as String?;
    final state = part['state'] as Map<String, dynamic>?;
    if (callId == null || toolName == null || state == null) return;

    var entry = session.transcript
        .whereType<ToolCallTranscriptEntry>()
        .where((e) => e.id == callId)
        .lastOrNull;
    if (entry == null) {
      entry = ToolCallTranscriptEntry(
        id: callId,
        name: toolName,
        argumentsJson: jsonEncode(state['input'] ?? const {}),
      );
      session.transcript.add(entry);
    } else {
      entry.argumentsJson = jsonEncode(state['input'] ?? const {});
    }

    switch (state['status'] as String?) {
      case 'completed':
        entry.status = ToolCallStatus.done;
        entry.resultText = state['output'] as String? ?? '';
      case 'error':
        entry.status = ToolCallStatus.error;
        entry.resultText = state['error'] as String? ?? '';
      case 'pending':
      case 'running':
        // Never regress a decision already made — a permission ask can still
        // be "pending"/"running" server-side while the user is looking at
        // the approval dialog, and a denial has already reached its terminal
        // state locally before opencode's own event for it arrives.
        if (entry.status != ToolCallStatus.awaitingApproval &&
            entry.status != ToolCallStatus.denied) {
          entry.status = ToolCallStatus.running;
        }
    }
    notifyListeners();
  }

  void _handlePermissionAsked(CodeSession session, OpencodePermissionEvent event) {
    final entry = session.transcript
        .whereType<ToolCallTranscriptEntry>()
        .where((e) => e.id == event.callId)
        .lastOrNull;
    if (entry == null) return; // the tool part event should always precede this

    entry.status = ToolCallStatus.awaitingApproval;
    notifyListeners();

    final completer = Completer<ToolApprovalDecision>();
    _pendingApproval = _PendingApproval(event.permissionId, entry, completer);
    _approvals.add(ToolApprovalRequest(
      toolName: entry.name,
      argsSummary: _summarizeArgs(entry),
      completer: completer,
    ));
    unawaited(_awaitApprovalDecision(session, event, completer));
  }

  Future<void> _awaitApprovalDecision(
    CodeSession session,
    OpencodePermissionEvent event,
    Completer<ToolApprovalDecision> completer,
  ) async {
    final decision = await completer.future;
    // stop() may already have resolved (and cleared) this same approval with
    // its own deny — don't double-reply or clobber a status it already set.
    if (_pendingApproval?.permissionId != event.permissionId) return;
    _pendingApproval = null;

    if (decision == ToolApprovalDecision.deny) {
      final entry = session.transcript
          .whereType<ToolCallTranscriptEntry>()
          .where((e) => e.id == event.callId)
          .lastOrNull;
      entry?.status = ToolCallStatus.denied;
      notifyListeners();
    }

    try {
      await _engine.client.respondToPermission(
        projectRoot: session.projectRoot ?? _projectRoot!,
        permissionId: event.permissionId,
        decision: decision,
      );
    } catch (e) {
      session.error = e.toString();
      notifyListeners();
    }
  }

  /// [_onEvent] already confirmed [opencodeSessionId] belongs to the current
  /// [_runGeneration] before calling this — the only run that can still be
  /// current — so `_running` always flips here regardless of which session
  /// the sidebar happens to be showing right now (switching the active
  /// session mid-run doesn't gate this, matching the old local-loop
  /// callbacks, which keyed off `generation` alone for the same reason).
  void _completeTurn(String opencodeSessionId) {
    _running = false;
    notifyListeners();
    _turnCompleters.remove(opencodeSessionId)?.complete();
  }

  String _summarizeArgs(ToolCallTranscriptEntry entry) {
    try {
      final decoded = jsonDecode(entry.argumentsJson);
      if (decoded is Map<String, dynamic>) {
        switch (entry.name) {
          case 'write':
          case 'edit':
          case 'patch':
            return decoded['filePath']?.toString() ??
                decoded['path']?.toString() ??
                entry.argumentsJson;
          case 'bash':
            return decoded['command']?.toString() ?? entry.argumentsJson;
        }
      }
    } on FormatException {
      // Fall through to the raw JSON below.
    }
    return entry.argumentsJson;
  }

  @override
  void dispose() {
    pool.removeListener(_onPoolChanged);
    unawaited(_eventSub?.cancel());
    unawaited(_engine.stop());
    _approvals.close();
    super.dispose();
  }
}
