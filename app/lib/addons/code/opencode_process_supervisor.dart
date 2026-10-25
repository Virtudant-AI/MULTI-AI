import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../api_client.dart' show apiBaseUrl;
import '../../chat_store.dart' show appDataFile;
import 'code_engine_installer.dart' show CodeEngineTool;
import 'code_engine_locator.dart';
import 'llama_server_supervisor.dart';

/// Owns the single `opencode serve` child process the Code tab drives
/// through `opencode_client.dart`. Unlike [LlamaServerSupervisor] (restarted
/// whenever the selected model's GGUF file changes), this is started once,
/// lazily, on the Code tab's first message, and left running for the rest of
/// the app's life: opencode's server can host any number of project
/// directories/sessions at once via a `directory` query parameter on every
/// request (confirmed empirically against a running server — not
/// documented), so a project-root change needs no restart here, only a new
/// session created against the new directory.
///
/// Mirrors `SearxngSupervisor` for the process-lifecycle shape (ping before
/// spawning, drain output, health-poll, stop/kill).
///
/// Ports in use: see `searxng_supervisor.dart`'s header comment — this adds
/// 8101.
class OpencodeProcessSupervisor {
  OpencodeProcessSupervisor({CodeEngineLocator? locator}) : _locator = locator ?? CodeEngineLocator();

  final CodeEngineLocator _locator;

  static const port = 8101;
  static const baseUrl = 'http://127.0.0.1:$port';

  /// The provider/model ids the generated config below registers — a fixed
  /// custom provider pointing at [LlamaServerSupervisor], not one of
  /// opencode's built-in hosted ones.
  static const providerId = 'multiai-local';
  static const modelId = 'local';

  /// A second custom provider, pointing at the Python backend's
  /// OpenAI-compatible route (`/v1/chat/completions` in `server.pyx`). Unlike
  /// [providerId]'s single `local` model, each server model is registered
  /// under its own id here, since the backend picks the model from the request.
  static const serverProviderId = 'multiai-server';

  Process? _process;

  /// Whether [_process] is a shell wrapping opencode rather than opencode
  /// itself — true only for an npm `.cmd` shim on Windows. [stop] needs to know,
  /// because ending the shell does not end what it started.
  bool _startedThroughShell = false;

  /// The server model ids the running process's config registered. A server
  /// model outside this set can't be selected without rewriting the config,
  /// which opencode only reads at startup — see [start].
  Set<String> _registeredServerModels = const {};

  bool get isRunning => _process != null;

  static Future<bool> ping({Duration timeout = const Duration(seconds: 1)}) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/config')).timeout(timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Points opencode at [LlamaServerSupervisor]'s OpenAI-compatible endpoint
  /// as a custom provider, and tightens its default permissions to this
  /// app's own gated-tool set (`edit`/`bash` ask — matches the read-tools-
  /// always-proceed / write-tools-gated split the old `agent_tools.dart`
  /// enforced by hand; `webfetch`/`websearch` off — the Code tab has no UI
  /// for either).
  ///
  /// Written to this app's own data directory and passed via `OPENCODE_CONFIG`
  /// rather than into the project folder or opencode's own global config:
  /// `PATCH /config?directory=<dir>` (the alternative, runtime-only way to
  /// set this) was confirmed to write a `config.json` straight into that
  /// directory — fine for opencode's own projects, not something this app
  /// should drop into an arbitrary user project.
  Future<File> _writeConfig(Set<String> serverModelIds) async {
    final file = await appDataFile('opencode_config.json');
    await file.writeAsString(jsonEncode({
      r'$schema': 'https://opencode.ai/config.json',
      'provider': {
        providerId: {
          'npm': '@ai-sdk/openai-compatible',
          'name': 'MULTI-AI (on-device)',
          'options': {'baseURL': 'http://127.0.0.1:${LlamaServerSupervisor.port}/v1'},
          'models': {
            modelId: {'name': 'On-device GGUF'},
          },
        },
        if (serverModelIds.isNotEmpty)
          serverProviderId: {
            'npm': '@ai-sdk/openai-compatible',
            'name': 'MULTI-AI (server)',
            'options': {'baseURL': '$apiBaseUrl/v1'},
            'models': {
              for (final id in serverModelIds) id: {'name': id},
            },
          },
      },
      'permission': {
        'edit': 'ask',
        'bash': 'ask',
        'webfetch': 'deny',
        'websearch': 'deny',
      },
    }));
    return file;
  }

  /// Starts `opencode serve` if nothing is already answering on [port]. See
  /// this class's doc comment for why a project-root or on-device model change
  /// never needs a restart here.
  ///
  /// [serverModelIds] are the backend models to register under
  /// [serverProviderId]. The config is only read at startup, so a process this
  /// supervisor started earlier is restarted when it's asked for a server model
  /// it didn't register (the backend was down on first start, say). A process
  /// it didn't start is left alone, as before.
  ///
  /// Throws [StateError] if the binary isn't on PATH, [Exception] if the
  /// process exits during startup, and [TimeoutException] if it never
  /// becomes healthy in time.
  Future<void> start({
    Set<String> serverModelIds = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (isRunning && !_registeredServerModels.containsAll(serverModelIds)) await stop();
    if (await ping()) return;

    final executable = await _locator.find(CodeEngineTool.opencode);
    if (executable == null) {
      throw StateError(
        "opencode wasn't found. Install the Code engine from the Code tab, or "
        'install opencode yourself (npm i -g opencode-ai, or see '
        'https://opencode.ai) and make sure it is on PATH.',
      );
    }

    final configFile = await _writeConfig(serverModelIds);
    _registeredServerModels = serverModelIds;

    // A `.cmd` shim (npm's) can't be launched by CreateProcess directly, so it
    // goes through the shell; a real executable — the app's own install, or the
    // one inside npm's package — never needs it.
    _startedThroughShell = Platform.isWindows && !executable.toLowerCase().endsWith('.exe');
    _process = await Process.start(
      executable,
      ['serve', '--port', '$port', '--hostname', '127.0.0.1'],
      environment: {'OPENCODE_CONFIG': configFile.path},
      runInShell: _startedThroughShell,
    );

    final log = StringBuffer();
    _process!.stdout.transform(utf8.decoder).listen(log.write);
    _process!.stderr.transform(utf8.decoder).listen(log.write);

    var exited = false;
    unawaited(_process!.exitCode.then((_) => exited = true));

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (exited) {
        _process = null;
        throw Exception('opencode serve exited during startup.\n\n$log');
      }
      if (await ping()) return;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    await stop();
    throw TimeoutException('opencode serve did not respond within ${timeout.inSeconds}s.\n\n$log');
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    if (_startedThroughShell) {
      // `process` is the shell around opencode, not opencode itself: `kill()`
      // would end the shell and leave opencode running, still holding [port] —
      // the next launch would adopt it. /T takes the whole tree down with it.
      await Process.run('taskkill', ['/T', '/F', '/PID', '${process.pid}']);
    } else {
      process.kill();
    }
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
