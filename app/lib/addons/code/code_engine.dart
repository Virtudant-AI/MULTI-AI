import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:llamadart/llamadart.dart';

import '../../api_client.dart' show ModelInfo, apiBaseUrl;
import '../../model_pool.dart';
import 'code_engine_installer.dart';
import 'code_engine_locator.dart';
import 'llama_server_supervisor.dart';
import 'opencode_client.dart';
import 'opencode_process_supervisor.dart';

/// What `CodeAgentController` needs to run a turn: somewhere to talk opencode
/// over HTTP ([client]), the provider/model ids that endpoint is registered
/// under, and a way to make sure both backing processes are up before using
/// it. Abstract so the controller stays unit-testable without spawning real
/// subprocesses — mirrors how `ProjectRootSource` is faked for the same
/// reason. [LocalCodeEngine] is the real implementation.
abstract class CodeEngine {
  OpencodeClient get client;

  /// The provider/model ids [model] is registered under in opencode's config —
  /// they differ by where the model runs, so they're per model, not fixed.
  String providerIdFor(ModelInfo model);
  String modelIdFor(ModelInfo model);

  /// Makes sure everything [model] needs is running, then `opencode serve`:
  /// for an on-device model, resolves its cached GGUF file and starts/reuses
  /// `llama-server`; for a server-side model, checks the Python backend
  /// serves it over its OpenAI-compatible route. Opencode comes last so it's
  /// never asked to relay a message before there's a model behind it.
  ///
  /// Throws [StateError] if [model] is neither on-device nor served by the
  /// backend, or if the backend can't be reached for a server-side model.
  Future<void> ensureRunning({required ModelInfo model});

  /// Whether the two external programs (`llama-server`, `opencode`) are
  /// available — installed by this app, or already on the machine.
  Future<bool> isInstalled();

  /// Whether this platform can install them for the user. When false the user
  /// installs them by hand (see the README's "Code tab" section).
  bool get canInstall;

  /// Downloads and installs the missing programs, reporting progress.
  Stream<CodeEngineProgress> install();

  /// The approximate download size of [install], for the button that starts it.
  int get installBytes;

  Future<void> stop();
}

/// Composes the two child processes the opencode-backed Code tab needs —
/// `llama-server` (serving the selected on-device model) and `opencode
/// serve` (running the actual agent loop against it). Lazy and
/// reuse-or-restart, mirroring `server.pyx`'s `_ensure_colibri_running`:
/// nothing spawns until the first message is sent, and an already-correct
/// process is left alone rather than bounced.
class LocalCodeEngine implements CodeEngine {
  LocalCodeEngine({
    LlamaServerSupervisor? llamaServer,
    OpencodeProcessSupervisor? opencode,
    OpencodeClient? client,
    Future<Set<String>> Function()? fetchServerModelIds,
    CodeEngineInstaller? installer,
    CodeEngineLocator? locator,
  })  : _installer = installer ?? CodeEngineInstaller(),
        _fetchServerModelIds = fetchServerModelIds ?? _fetchBackendModelIds,
        client = client ?? HttpOpencodeClient(baseUrl: OpencodeProcessSupervisor.baseUrl) {
    // One locator shared by the engine and both supervisors, so "is it
    // installed?" and "where do I launch it from?" can never disagree.
    _locator = locator ?? CodeEngineLocator(installer: _installer);
    _llamaServer = llamaServer ?? LlamaServerSupervisor(locator: _locator);
    _opencode = opencode ?? OpencodeProcessSupervisor(locator: _locator);
  }

  final CodeEngineInstaller _installer;
  late final CodeEngineLocator _locator;
  late final LlamaServerSupervisor _llamaServer;
  late final OpencodeProcessSupervisor _opencode;
  final Future<Set<String>> Function() _fetchServerModelIds;

  @override
  final OpencodeClient client;

  @override
  String providerIdFor(ModelInfo model) => _isOnDevice(model)
      ? OpencodeProcessSupervisor.providerId
      : OpencodeProcessSupervisor.serverProviderId;

  @override
  String modelIdFor(ModelInfo model) =>
      _isOnDevice(model) ? OpencodeProcessSupervisor.modelId : model.id;

  static bool _isOnDevice(ModelInfo model) => ModelPool.localSourceOf(model) != null;

  /// The ids the Python backend's `GET /v1/models` lists.
  static Future<Set<String>> _fetchBackendModelIds() async {
    final response = await http
        .get(Uri.parse('$apiBaseUrl/v1/models'))
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw StateError('the backend answered /v1/models with HTTP ${response.statusCode}');
    }
    final data = (jsonDecode(response.body) as Map<String, dynamic>)['data'] as List<dynamic>;
    return {for (final m in data) (m as Map<String, dynamic>)['id'] as String};
  }

  @override
  Future<void> ensureRunning({required ModelInfo model}) async {
    final source = ModelPool.localSourceOf(model);
    if (source != null) {
      final ggufPath = await _resolveGgufPath(source);
      await _llamaServer.start(ggufPath);
      // Opencode still gets every server model registered, so switching to
      // one later doesn't force a restart. Best effort: with the backend
      // down there are simply none, which only matters if one is picked.
      await _opencode.start(serverModelIds: await _serverModelIdsOrEmpty());
      return;
    }

    final Set<String> served;
    try {
      served = await _fetchServerModelIds();
    } catch (e) {
      throw StateError(
        "Couldn't reach the Multi-AI backend at $apiBaseUrl to use ${model.name} "
        '($e). Start it, or pick an on-device model.',
      );
    }
    if (!served.contains(model.id)) {
      throw StateError(
        "The backend doesn't serve ${model.name} over its OpenAI-compatible "
        'route — it needs server-side weights.',
      );
    }
    await _opencode.start(serverModelIds: served);
  }

  Future<Set<String>> _serverModelIdsOrEmpty() async {
    try {
      return await _fetchServerModelIds();
    } catch (_) {
      return const {};
    }
  }

  Future<String> _resolveGgufPath(String hfSource) async {
    // The same cache llamadart's own on-device chat engine uses (see
    // on_device_engine.dart's identical ensureModel call for its mmproj
    // file) — a cache hit here, not a fresh download, since the Code tab
    // only lists models `ModelPool` already reports as downloaded.
    final manager = DefaultModelDownloadManager();
    final entry = await manager.ensureModel(ModelSource.parse(hfSource));
    return entry.filePath;
  }

  @override
  Future<bool> isInstalled() async =>
      await _locator.find(CodeEngineTool.llamaServer) != null &&
      await _locator.find(CodeEngineTool.opencode) != null;

  @override
  bool get canInstall => _installer.pins.isNotEmpty;

  @override
  Stream<CodeEngineProgress> install() => _installer.install();

  @override
  int get installBytes => _installer.totalBytes;

  @override
  Future<void> stop() async {
    await _opencode.stop();
    await _llamaServer.stop();
    await client.close();
  }
}
