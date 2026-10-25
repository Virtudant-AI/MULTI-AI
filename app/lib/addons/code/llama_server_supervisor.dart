import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'code_engine_installer.dart' show CodeEngineTool;
import 'code_engine_locator.dart';

/// Owns the `llama-server` child process serving the Code tab's currently
/// selected on-device GGUF model over an OpenAI-compatible API, so opencode
/// (a separate process — see `opencode_process_supervisor.dart`) has
/// something real to point at. `llamadart`'s own engine
/// (`on_device_engine.dart`) runs embedded, in-process, with no HTTP server
/// mode, so this is a second, independent inference process for the Code
/// tab specifically — on-device chat keeps using llamadart directly and is
/// unaffected.
///
/// Mirrors `SearxngSupervisor` (`addons/components/searxng_supervisor.dart`):
/// ping before spawning so an already-running instance is adopted rather
/// than raced against for the port, drain stdout/stderr into a log buffer
/// surfaced only on failure, health-poll with a timeout, `stop()` kills it.
///
/// Ports in use: see `searxng_supervisor.dart`'s header comment — this adds
/// 8100.
class LlamaServerSupervisor {
  LlamaServerSupervisor({CodeEngineLocator? locator}) : _locator = locator ?? CodeEngineLocator();

  static const port = 8100;

  final CodeEngineLocator _locator;

  Process? _process;
  String? _loadedModelPath;

  bool get isRunning => _process != null;

  /// The GGUF file currently being served, or null if not running.
  String? get loadedModelPath => _loadedModelPath;

  static Future<bool> ping({Duration timeout = const Duration(seconds: 1)}) async {
    try {
      final response =
          await http.get(Uri.parse('http://127.0.0.1:$port/health')).timeout(timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Starts `llama-server` for [ggufPath] and waits for it to answer. No-op
  /// if it's already serving that exact file. Loading a multi-gigabyte model
  /// can take a while, hence the generous default timeout — see
  /// `CodeEngine.ensureRunning` for the reuse-or-restart policy one layer up
  /// (a different [ggufPath] stops the old process first).
  ///
  /// Throws [StateError] if the binary can't be found (see
  /// [CodeEngineLocator]), [Exception] if the process exits during startup,
  /// and [TimeoutException] if it never becomes healthy in time.
  Future<void> start(String ggufPath, {Duration timeout = const Duration(seconds: 90)}) async {
    if (_loadedModelPath == ggufPath && await ping()) return;
    await stop();

    final executable = await _locator.find(CodeEngineTool.llamaServer);
    if (executable == null) {
      throw StateError(
        "llama-server wasn't found. Install the Code engine from the Code tab, "
        'or install llama.cpp yourself (https://github.com/ggml-org/llama.cpp/releases) '
        'and put llama-server on PATH.',
      );
    }

    // --jinja enables llama.cpp's own chat-template-driven tool-call
    // grammar/parsing (per-model-family, not just Qwen's tag) — this is the
    // whole reason the Code tab no longer needs to prompt for a text tag
    // itself. See the README's "Code tab" section.
    _process = await Process.start(
      executable,
      ['-m', ggufPath, '--port', '$port', '--jinja'],
    );
    _loadedModelPath = ggufPath;

    // Drained rather than ignored — an unread pipe fills its buffer and
    // blocks the child mid-write (same reasoning as BackendSupervisor.start()
    // in backend_process.dart).
    final log = StringBuffer();
    _process!.stdout.transform(utf8.decoder).listen(log.write);
    _process!.stderr.transform(utf8.decoder).listen(log.write);

    var exited = false;
    unawaited(_process!.exitCode.then((_) => exited = true));

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (exited) {
        _process = null;
        _loadedModelPath = null;
        throw Exception('llama-server exited during startup.\n\n$log');
      }
      if (await ping()) return;
      await Future.delayed(const Duration(milliseconds: 400));
    }
    await stop();
    throw TimeoutException('llama-server did not respond within ${timeout.inSeconds}s.\n\n$log');
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    _loadedModelPath = null;
    if (process == null) return;
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
