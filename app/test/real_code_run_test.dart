// A manual smoke test of the Code tab against the real thing: it starts a
// real `llama-server` and `opencode serve` through [LocalCodeEngine], sends one
// prompt, and checks the model actually used opencode's `read` tool.
//
// Skipped unless MULTI_AI_REAL_RUN=1, because it needs both binaries on PATH
// and a downloaded GGUF (it uses the app's own llamadart cache), and it takes
// minutes. Run it with:
//
//   $env:MULTI_AI_REAL_RUN = '1'
//   flutter test test/real_code_run_test.dart
//
// MULTI_AI_REAL_GGUF overrides the model source (an hf:// GGUF URL).
//
// MULTI_AI_REAL_INSTALL=1 first runs the app's own one-click installer (a real
// ~98 MB download from GitHub) into a temp folder and requires the run to use
// *those* binaries — the path a user without llama-server/opencode takes.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:multi_ai/addons/code/code_engine.dart';
import 'package:multi_ai/addons/code/code_engine_installer.dart';
import 'package:multi_ai/addons/code/code_engine_locator.dart';
import 'package:multi_ai/addons/code/opencode_client.dart';
import 'package:multi_ai/addons/code/opencode_process_supervisor.dart';
import 'package:multi_ai/api_client.dart';

class _TempPaths extends PathProviderPlatform {
  _TempPaths(this.dir);
  final String dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  final enabled = Platform.environment['MULTI_AI_REAL_RUN'] == '1';
  final realInstall = Platform.environment['MULTI_AI_REAL_INSTALL'] == '1';
  final source = Platform.environment['MULTI_AI_REAL_GGUF'] ??
      'hf://unsloth/Qwen2.5-Coder-1.5B-Instruct-GGUF/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf';

  test(
    'an on-device model reads a file through opencode',
    () async {
      final support = await Directory.systemTemp.createTemp('real_run_support');
      final project = await Directory.systemTemp.createTemp('real_run_project');
      addTearDown(() async {
        await support.delete(recursive: true);
        await project.delete(recursive: true);
      });
      // The supervisor adopts whatever already answers on its port, so a
      // leftover opencode (from an earlier run, or the app itself) would be
      // used with its own stale config instead of the one this test writes.
      expect(
        await OpencodeProcessSupervisor.ping(),
        isFalse,
        reason: 'something is already serving on port ${OpencodeProcessSupervisor.port} — '
            'stop that opencode first so this run starts its own',
      );
      PathProviderPlatform.instance = _TempPaths(support.path);
      await File('${project.path}${Platform.pathSeparator}hello.txt')
          .writeAsString('The secret word is PINEAPPLE.\n');

      final engineRoot = await Directory.systemTemp.createTemp('real_run_engine');
      addTearDown(() => engineRoot.delete(recursive: true));
      final installer = CodeEngineInstaller(rootDirectory: () async => engineRoot);
      final locator = CodeEngineLocator(installer: installer);
      final engine = LocalCodeEngine(installer: installer, locator: locator);
      addTearDown(engine.stop);

      if (realInstall) {
        expect(CodeEngineInstaller.supported, isTrue, reason: 'the installer targets Windows x64');
        final steps = <String>[];
        await for (final progress in engine.install()) {
          if (steps.isEmpty || steps.last != progress.message) steps.add(progress.message);
        }
        // ignore: avoid_print
        print('install steps: $steps');
        // The binaries used must be the ones just installed, not any already on
        // the machine.
        for (final tool in CodeEngineTool.values) {
          final path = await locator.find(tool);
          expect(path, isNotNull, reason: tool.id);
          expect(path!.startsWith(engineRoot.path), isTrue,
              reason: '${tool.id} resolved to $path, outside the fresh install in ${engineRoot.path}');
        }
      }
      final model = ModelInfo(id: 'real_run', name: 'Real run', gguf: source);

      await engine.ensureRunning(model: model);

      final tools = <String, String>{};
      final texts = <String, String>{};
      final done = Completer<String?>();
      late final StreamSubscription<OpencodeEvent> sub;
      final root = project.path;

      final sessionId = await engine.client.createSession(root);
      sub = engine.client.events(root).listen((event) {
        if (event.sessionId != sessionId) return;
        switch (event) {
          case OpencodePartEvent(:final part):
            if (part['type'] == 'tool') {
              final status = (part['state'] as Map)['status'];
              tools['${part['tool']}'] = '$status';
              // ignore: avoid_print
              print('tool ${part['tool']} -> $status');
            } else if (part['type'] == 'text') {
              texts['${part['id']}'] = '${part['text']}';
            }
          case OpencodePermissionEvent():
            // The prompt only needs the read tool, which never asks.
            // ignore: avoid_print
            print('unexpected permission request');
          case OpencodeSessionIdleEvent():
            if (!done.isCompleted) done.complete(null);
          case OpencodeSessionErrorEvent(:final message):
            if (!done.isCompleted) done.complete(message);
        }
      });
      addTearDown(sub.cancel);

      await engine.client.sendMessageAsync(
        projectRoot: root,
        sessionId: sessionId,
        providerId: engine.providerIdFor(model),
        modelId: engine.modelIdFor(model),
        text: 'Use your read tool to read hello.txt, then tell me the secret word.',
      );

      final error = await done.future.timeout(const Duration(minutes: 5));
      final answer = texts.values.join('\n');
      // ignore: avoid_print
      print('tools: $tools\nanswer: $answer\nerror: $error');

      expect(error, isNull);
      expect(tools['read'], 'completed', reason: 'the model never completed a read call');
      expect(answer, contains('PINEAPPLE'));
    },
    skip: enabled ? false : 'set MULTI_AI_REAL_RUN=1 to run against real binaries',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
