import 'dart:io';

import 'code_engine_installer.dart';

/// Finds the Code tab's external programs on disk.
///
/// Looking only on `PATH` is not enough: WinGet installs `llama-server` and npm
/// installs `opencode` without ever putting their folders on the `PATH` a
/// freshly launched app inherits, so a perfectly good install read as "not
/// installed". The order is the one that respects the user's intent:
///
///  1. the copy this app installed itself ([CodeEngineInstaller]),
///  2. whatever is on `PATH`,
///  3. the places the usual install methods put it.
class CodeEngineLocator {
  CodeEngineLocator({
    CodeEngineInstaller? installer,
    Map<String, String>? environment,
    bool? isWindows,
    this.findOnPath,
  })  : _installer = installer ?? CodeEngineInstaller(),
        _env = environment ?? Platform.environment,
        _isWindows = isWindows ?? Platform.isWindows;

  final CodeEngineInstaller _installer;
  final Map<String, String> _env;
  final bool _isWindows;

  /// Replaces the `where`/`which` lookup — for tests, which must not depend on
  /// what the machine running them happens to have installed.
  final Future<String?> Function(String name)? findOnPath;

  /// The full path to run [tool], or null if it can't be found anywhere.
  Future<String?> find(CodeEngineTool tool) async {
    final installed = await _findInstalled(tool);
    if (installed != null) return installed;

    final onPath = await (findOnPath ?? _whereOrWhich)(tool.id);
    if (onPath != null) return onPath;

    for (final candidate in await _knownLocations(tool)) {
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  Future<String?> _findInstalled(CodeEngineTool tool) async {
    final pin = _installer.pins[tool];
    if (pin == null || !await _installer.isInstalled(pin)) return null;
    final dir = await _installer.installDirFor(pin);
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File &&
          entity.uri.pathSegments.last.toLowerCase() == tool.executableName.toLowerCase()) {
        return entity.path;
      }
    }
    return null;
  }

  Future<String?> _whereOrWhich(String name) async {
    try {
      final result = await Process.run(_isWindows ? 'where' : 'which', [name]);
      if (result.exitCode != 0) return null;
      // `where` lists every match. An extensionless shim (npm leaves one beside
      // its `.cmd`) isn't runnable on Windows, so prefer a real executable.
      final lines = (result.stdout as String)
          .split(RegExp(r'\r?\n'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) return null;
      if (!_isWindows) return lines.first;
      const runnable = ['.exe', '.cmd', '.bat'];
      return lines.firstWhere(
        (l) => runnable.any(l.toLowerCase().endsWith),
        orElse: () => lines.first,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _knownLocations(CodeEngineTool tool) async {
    final sep = _isWindows ? r'\' : '/';
    String join(Iterable<String> parts) => parts.join(sep);
    final home = _env[_isWindows ? 'USERPROFILE' : 'HOME'];
    final found = <String>[];

    if (_isWindows) {
      final local = _env['LOCALAPPDATA'] ?? (home == null ? null : join([home, 'AppData', 'Local']));
      final roaming = _env['APPDATA'] ?? (home == null ? null : join([home, 'AppData', 'Roaming']));
      switch (tool) {
        case CodeEngineTool.llamaServer:
          if (local != null) {
            found.add(join([local, 'Microsoft', 'WinGet', 'Links', 'llama-server.exe']));
            // WinGet unpacks the package into a folder named for it and its
            // source, which isn't predictable beyond its prefix.
            final packages = Directory(join([local, 'Microsoft', 'WinGet', 'Packages']));
            if (await packages.exists()) {
              await for (final entry in packages.list(followLinks: false)) {
                if (entry is Directory &&
                    entry.uri.pathSegments.where((s) => s.isNotEmpty).last.toLowerCase().startsWith('ggml.llamacpp')) {
                  found.add(join([entry.path, 'llama-server.exe']));
                }
              }
            }
          }
        case CodeEngineTool.opencode:
          if (roaming != null) {
            // The real executable inside npm's package, ahead of the `.cmd`
            // shim: it needs no shell to launch, and killing it ends opencode
            // itself rather than only the shell around it.
            found.add(join([roaming, 'npm', 'node_modules', 'opencode-ai', 'bin', 'opencode.exe']));
            found.add(join([roaming, 'npm', 'opencode.cmd']));
          }
          if (home != null) found.add(join([home, '.opencode', 'bin', 'opencode.exe']));
      }
    } else {
      final name = tool.executableBase;
      if (home != null) {
        if (tool == CodeEngineTool.opencode) found.add(join([home, '.opencode', 'bin', name]));
        found.add(join([home, '.local', 'bin', name]));
      }
      found.addAll(['/usr/local/bin/$name', '/opt/homebrew/bin/$name']);
    }
    return found;
  }
}
