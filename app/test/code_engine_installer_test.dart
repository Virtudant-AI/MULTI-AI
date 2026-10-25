import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:multi_ai/addons/code/code_engine_installer.dart';

/// A zip holding [files] (path -> text), the way a release archive does.
List<int> _zip(Map<String, String> files) {
  final archive = Archive();
  files.forEach((path, text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive);
}

CodeEnginePin _pinFor(CodeEngineTool tool, List<int> zipBytes, {String? sha}) => CodeEnginePin(
      tool: tool,
      version: '1.0.0',
      url: 'https://example.test/${tool.id}.zip',
      sha256: sha ?? sha256.convert(zipBytes).toString(),
      sizeBytes: zipBytes.length,
    );

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('code_engine_installer_test');
  });
  tearDown(() async {
    // The uninstall test has already removed it.
    if (await root.exists()) await root.delete(recursive: true);
  });

  CodeEngineInstaller installer(
    Map<CodeEngineTool, CodeEnginePin> pins,
    http.Client client,
  ) =>
      CodeEngineInstaller(pins: pins, rootDirectory: () async => root, client: client);

  final exe = CodeEngineTool.opencode.executableName;

  test('downloads, verifies, unpacks and marks a tool installed', () async {
    final zip = _zip({'bin/$exe': 'binary', 'bin/readme.txt': 'hi'});
    final pin = _pinFor(CodeEngineTool.opencode, zip);
    final requests = <Uri>[];
    final inst = installer({
      CodeEngineTool.opencode: pin,
    }, MockClient((request) async {
      requests.add(request.url);
      return http.Response.bytes(zip, 200);
    }));

    expect(await inst.isInstalled(pin), isFalse);
    final progress = await inst.install().toList();

    expect(requests.single.toString(), pin.url);
    expect(await inst.isInstalled(pin), isTrue);
    final dir = await inst.installDirFor(pin);
    expect(File('${dir.path}${Platform.pathSeparator}bin${Platform.pathSeparator}$exe').existsSync(), isTrue);
    expect(progress.last.message, 'Installed opencode.');
    expect(progress.last.fraction, 1);
    // Reported as it went: downloading, then unpacking, then done.
    expect(progress.any((p) => p.message.startsWith('Downloading')), isTrue);
    expect(progress.any((p) => p.message.startsWith('Unpacking')), isTrue);
    final fractions = [for (final p in progress) if (p.fraction != null) p.fraction!];
    expect(fractions, orderedEquals([...fractions]..sort()), reason: 'progress never goes backwards');
  });

  test('leaves no partial download behind after a successful install', () async {
    final zip = _zip({exe: 'binary'});
    final pin = _pinFor(CodeEngineTool.opencode, zip);
    final inst = installer({CodeEngineTool.opencode: pin},
        MockClient((_) async => http.Response.bytes(zip, 200)));
    await inst.install().drain<void>();

    final dir = await inst.installDirFor(pin);
    expect(Directory('${dir.path}.partial').existsSync(), isFalse);
    expect(File('${dir.path}${Platform.pathSeparator}download.zip').existsSync(), isFalse);
  });

  test('a checksum mismatch is discarded, never unpacked or marked installed', () async {
    final zip = _zip({exe: 'tampered'});
    final pin = _pinFor(CodeEngineTool.opencode, zip, sha: 'a' * 64);
    final inst = installer({CodeEngineTool.opencode: pin},
        MockClient((_) async => http.Response.bytes(zip, 200)));

    await expectLater(
      inst.install().drain<void>(),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('checksum'))),
    );

    expect(await inst.isInstalled(pin), isFalse);
    final dir = await inst.installDirFor(pin);
    expect(dir.existsSync(), isFalse);
    expect(Directory('${dir.path}.partial').existsSync(), isFalse);
  });

  test('an HTTP error is reported and nothing is installed', () async {
    final zip = _zip({exe: 'binary'});
    final pin = _pinFor(CodeEngineTool.opencode, zip);
    final inst = installer({CodeEngineTool.opencode: pin},
        MockClient((_) async => http.Response('nope', 404)));

    await expectLater(
      inst.install().drain<void>(),
      throwsA(isA<HttpException>().having((e) => e.message, 'message', contains('404'))),
    );
    expect(await inst.isInstalled(pin), isFalse);
  });

  test('an archive without the expected executable is rejected', () async {
    final zip = _zip({'something_else.txt': 'x'});
    final pin = _pinFor(CodeEngineTool.opencode, zip);
    final inst = installer({CodeEngineTool.opencode: pin},
        MockClient((_) async => http.Response.bytes(zip, 200)));

    await expectLater(
      inst.install().drain<void>(),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains(exe))),
    );
    expect(await inst.isInstalled(pin), isFalse);
  });

  test('a tool that is already installed is not downloaded again', () async {
    final zip = _zip({exe: 'binary'});
    final pin = _pinFor(CodeEngineTool.opencode, zip);
    var requests = 0;
    final inst = installer({CodeEngineTool.opencode: pin}, MockClient((_) async {
      requests++;
      return http.Response.bytes(zip, 200);
    }));

    await inst.install().drain<void>();
    await inst.install().drain<void>();

    expect(requests, 1);
  });

  test('an install whose executable was later deleted (antivirus) is not installed, and reinstalls',
      () async {
    final zip = _zip({'bin/$exe': 'binary'});
    final pin = _pinFor(CodeEngineTool.opencode, zip);
    var requests = 0;
    final inst = installer({CodeEngineTool.opencode: pin}, MockClient((_) async {
      requests++;
      return http.Response.bytes(zip, 200);
    }));
    await inst.install().drain<void>();
    expect(await inst.isInstalled(pin), isTrue);

    final dir = await inst.installDirFor(pin);
    File('${dir.path}${Platform.pathSeparator}bin${Platform.pathSeparator}$exe').deleteSync();

    expect(await inst.isInstalled(pin), isFalse, reason: 'the marker alone must not count');
    await inst.install().drain<void>();
    expect(requests, 2);
    expect(await inst.isInstalled(pin), isTrue);
  });

  test('installs every pinned tool, one after another', () async {
    final llama = _zip({CodeEngineTool.llamaServer.executableName: 'llama'});
    final opencode = _zip({exe: 'agent'});
    final pins = {
      CodeEngineTool.llamaServer: _pinFor(CodeEngineTool.llamaServer, llama),
      CodeEngineTool.opencode: _pinFor(CodeEngineTool.opencode, opencode),
    };
    final inst = installer(pins, MockClient((request) async {
      return http.Response.bytes(request.url.path.contains('llama') ? llama : opencode, 200);
    }));

    await inst.install().drain<void>();

    for (final pin in pins.values) {
      expect(await inst.isInstalled(pin), isTrue, reason: pin.tool.id);
    }
    expect(inst.totalBytes, llama.length + opencode.length);
  });

  test('with no pins (an unsupported platform) install explains what to do instead', () async {
    final inst = CodeEngineInstaller(pins: const {}, rootDirectory: () async => root);
    await expectLater(
      inst.install().drain<void>(),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('put them on PATH'))),
    );
  });

  test('uninstall removes everything', () async {
    final zip = _zip({exe: 'binary'});
    final pin = _pinFor(CodeEngineTool.opencode, zip);
    final inst = installer({CodeEngineTool.opencode: pin},
        MockClient((_) async => http.Response.bytes(zip, 200)));
    await inst.install().drain<void>();

    await inst.uninstall();

    expect(await inst.isInstalled(pin), isFalse);
  });

  test('the shipped pins point at pinned releases with a full-length checksum', () {
    for (final pin in codeEngineWindowsX64Pins.values) {
      expect(pin.url, startsWith('https://github.com/'));
      expect(pin.url, endsWith('.zip'));
      expect(pin.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: pin.tool.id);
      expect(pin.sizeBytes, greaterThan(1000000));
      // Pinned: a version in the URL, never a "latest" redirect.
      expect(pin.url, isNot(contains('latest')));
    }
  });
}
