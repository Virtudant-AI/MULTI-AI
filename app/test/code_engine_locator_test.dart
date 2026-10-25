import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:multi_ai/addons/code/code_engine_installer.dart';
import 'package:multi_ai/addons/code/code_engine_locator.dart';

// The known-location search is Windows-specific (WinGet, npm's %APPDATA% folder),
// and these tests build Windows paths on disk.
final _windowsOnly = Platform.isWindows ? null : 'Windows install locations';

void main() {
  late Directory home; // stands in for the user's profile
  late Directory engineRoot; // where the app's own installer puts things

  setUp(() async {
    home = await Directory.systemTemp.createTemp('locator_home');
    engineRoot = await Directory.systemTemp.createTemp('locator_engine');
  });
  tearDown(() async {
    await home.delete(recursive: true);
    await engineRoot.delete(recursive: true);
  });

  const sep = r'\';
  String local() => '${home.path}${sep}AppData${sep}Local';
  String roaming() => '${home.path}${sep}AppData${sep}Roaming';

  Future<File> touch(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString('x');
    return file;
  }

  CodeEngineLocator locatorWith({String? onPath}) => CodeEngineLocator(
        installer: CodeEngineInstaller(
          pins: const {
            CodeEngineTool.llamaServer: CodeEnginePin(
              tool: CodeEngineTool.llamaServer,
              version: 'b1',
              url: 'https://example.test/l.zip',
              sha256: '',
              sizeBytes: 1,
            ),
            CodeEngineTool.opencode: CodeEnginePin(
              tool: CodeEngineTool.opencode,
              version: '1.0.0',
              url: 'https://example.test/o.zip',
              sha256: '',
              sizeBytes: 1,
            ),
          },
          rootDirectory: () async => engineRoot,
        ),
        environment: {
          'USERPROFILE': home.path,
          'LOCALAPPDATA': local(),
          'APPDATA': roaming(),
        },
        isWindows: true,
        findOnPath: (name) async => onPath,
      );

  /// Marks the pinned [tool] as installed by the app, the way the installer does.
  Future<String> installManaged(CodeEngineTool tool, String version) async {
    final dir = '${engineRoot.path}$sep${tool.id}$sep$version';
    await File('$dir$sep.installed').create(recursive: true);
    return (await touch('$dir${sep}bin$sep${tool.executableName}')).path;
  }

  test('finds nothing when nothing is installed anywhere', () async {
    final locator = locatorWith();
    expect(await locator.find(CodeEngineTool.llamaServer), isNull);
    expect(await locator.find(CodeEngineTool.opencode), isNull);
  }, skip: _windowsOnly);

  test("prefers the app's own install over everything else", () async {
    final managed = await installManaged(CodeEngineTool.opencode, '1.0.0');
    await touch('${roaming()}${sep}npm${sep}node_modules${sep}opencode-ai${sep}bin${sep}opencode.exe');

    final found = await locatorWith(onPath: r'C:\on\path\opencode.cmd').find(CodeEngineTool.opencode);

    expect(found, managed);
  }, skip: _windowsOnly);

  test('an install of a different version than the pinned one is not used', () async {
    await installManaged(CodeEngineTool.opencode, '0.9.0');
    expect(await locatorWith().find(CodeEngineTool.opencode), isNull);
  }, skip: _windowsOnly);

  test('an unfinished install (no marker) is ignored', () async {
    final dir = '${engineRoot.path}${sep}opencode${sep}1.0.0';
    await touch('$dir${sep}opencode.exe'); // exe present, marker absent
    expect(await locatorWith().find(CodeEngineTool.opencode), isNull);
  }, skip: _windowsOnly);

  test('uses whatever is on PATH when the app has not installed its own', () async {
    final found = await locatorWith(onPath: r'C:\tools\llama-server.exe').find(CodeEngineTool.llamaServer);
    expect(found, r'C:\tools\llama-server.exe');
  }, skip: _windowsOnly);

  test("finds a WinGet install that isn't on PATH", () async {
    final exe = await touch(
        '${local()}${sep}Microsoft${sep}WinGet${sep}Packages${sep}ggml.llamacpp_Microsoft.Winget.Source_8wekyb3d8bbwe${sep}llama-server.exe');

    expect(await locatorWith().find(CodeEngineTool.llamaServer), exe.path);
  }, skip: _windowsOnly);

  test('ignores WinGet packages that are not llama.cpp', () async {
    await touch('${local()}${sep}Microsoft${sep}WinGet${sep}Packages${sep}Other.Tool_x${sep}llama-server.exe');
    expect(await locatorWith().find(CodeEngineTool.llamaServer), isNull);
  }, skip: _windowsOnly);

  test("finds npm's opencode and prefers the real exe over the .cmd shim", () async {
    await touch('${roaming()}${sep}npm${sep}opencode.cmd');
    final exe = await touch(
        '${roaming()}${sep}npm${sep}node_modules${sep}opencode-ai${sep}bin${sep}opencode.exe');

    expect(await locatorWith().find(CodeEngineTool.opencode), exe.path);
  }, skip: _windowsOnly);

  test('falls back to npm\'s .cmd shim when that is all there is', () async {
    final shim = await touch('${roaming()}${sep}npm${sep}opencode.cmd');
    expect(await locatorWith().find(CodeEngineTool.opencode), shim.path);
  }, skip: _windowsOnly);

  test("finds opencode's own installer location", () async {
    final exe = await touch('${home.path}$sep.opencode${sep}bin${sep}opencode.exe');
    expect(await locatorWith().find(CodeEngineTool.opencode), exe.path);
  }, skip: _windowsOnly);

  test('the two tools are looked up independently', () async {
    final llama = await installManaged(CodeEngineTool.llamaServer, 'b1');
    final locator = locatorWith();
    expect(await locator.find(CodeEngineTool.llamaServer), llama);
    expect(await locator.find(CodeEngineTool.opencode), isNull);
  }, skip: _windowsOnly);
}
