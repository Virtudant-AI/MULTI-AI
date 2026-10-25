import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart' show getApplicationSupportDirectory;

/// The two external programs the Code tab runs: `llama-server` serves the
/// selected on-device model, `opencode serve` runs the agent loop against it.
enum CodeEngineTool {
  llamaServer('llama-server', 'llama-server'),
  opencode('opencode', 'opencode');

  const CodeEngineTool(this.id, this.executableBase);

  /// Stable name: the subdirectory this tool installs into, and what a user
  /// types to run it.
  final String id;

  /// The executable's file name without its platform extension.
  final String executableBase;

  String get executableName => Platform.isWindows ? '$executableBase.exe' : executableBase;
}

/// One downloadable release of a [CodeEngineTool]: where to get it, and the
/// checksum it must match. Pinned rather than "latest" on purpose — this app's
/// opencode client speaks an undocumented API that was only confirmed against
/// one release (see `opencode_client.dart`), and llama-server's request
/// handling has changed between builds, so an unpinned download could break the
/// Code tab with nothing in this repo having changed.
class CodeEnginePin {
  const CodeEnginePin({
    required this.tool,
    required this.version,
    required this.url,
    required this.sha256,
    required this.sizeBytes,
  });

  final CodeEngineTool tool;

  /// Names the version's install directory, so a newer pin installs beside the
  /// old one instead of on top of it.
  final String version;

  final String url;

  /// Lower-case hex SHA-256 of the downloaded zip. A download that doesn't
  /// match is discarded, never unpacked.
  final String sha256;

  /// Expected download size — for the progress bar when the server omits a
  /// Content-Length, and the size shown to the user before they install.
  final int sizeBytes;
}

/// The pins for Windows x64, the only platform this installer targets: the
/// release asset naming for the others differs, and Linux/macOS users
/// overwhelmingly have a package manager. Everyone else installs the two
/// programs themselves (see the README's "Code tab" section).
///
/// llama.cpp's Vulkan build, not CUDA: 32 MB against ~580 MB (the CUDA zip plus
/// its separate runtime zip), and it runs on NVIDIA, AMD and Intel GPUs alike.
/// It is somewhat slower than CUDA on an NVIDIA card; a CUDA option is future work.
///
/// b11193 rather than the newest build, for two reasons. It is the build the Code
/// tab was validated end to end against. And a build that has been in circulation
/// for a while (it is also what `winget install ggml.llamacpp` fetched) is one
/// antivirus reputation systems already know: Norton 360 deleted the unsigned
/// `llama-server.exe` launcher from a build published hours earlier, straight
/// after it was installed, and left this one alone. Bump it deliberately and
/// re-run `test/real_code_run_test.dart` with MULTI_AI_REAL_INSTALL=1.
const codeEngineWindowsX64Pins = <CodeEngineTool, CodeEnginePin>{
  CodeEngineTool.llamaServer: CodeEnginePin(
    tool: CodeEngineTool.llamaServer,
    version: 'b11193-vulkan',
    url: 'https://github.com/ggml-org/llama.cpp/releases/download/b11193/'
        'llama-b11193-bin-win-vulkan-x64.zip',
    sha256: 'a106346b30d79883626bd9cf9f0d787ff949eeaf3feaf6a4f31d41a2ecf9086b',
    sizeBytes: 32469216,
  ),
  CodeEngineTool.opencode: CodeEnginePin(
    tool: CodeEngineTool.opencode,
    version: '1.18.29',
    url: 'https://github.com/anomalyco/opencode/releases/download/v1.18.29/'
        'opencode-windows-x64.zip',
    sha256: 'b32618aa3d1415f6e4f473aec248edef25759203fb707d7d968359d86d4a35ee',
    sizeBytes: 60655378,
  ),
};

/// One line of install progress. [fraction] is 0..1 for a step with a known
/// length (a download) and null otherwise (unpacking, verifying).
class CodeEngineProgress {
  const CodeEngineProgress(this.message, {this.fraction});

  final String message;
  final double? fraction;
}

/// Where the Code engine's programs are installed, and the installer that puts
/// them there. The app's own data folder, not anywhere on `PATH`: installing
/// must not need admin rights or touch the user's environment, and deleting
/// that folder is a full uninstall.
class CodeEngineInstaller {
  CodeEngineInstaller({
    Map<CodeEngineTool, CodeEnginePin>? pins,
    Future<Directory> Function()? rootDirectory,
    this.client,
  })  : pins = pins ?? (supported ? codeEngineWindowsX64Pins : const {}),
        _rootDirectory = rootDirectory ?? _defaultRoot;

  /// Windows x64 only — see [codeEngineWindowsX64Pins].
  static bool get supported => Platform.isWindows && Platform.version.contains('x64');

  final Map<CodeEngineTool, CodeEnginePin> pins;
  final Future<Directory> Function() _rootDirectory;

  /// Injected by tests; null means a client is made (and closed) per install.
  final http.Client? client;

  /// Total download size across [pins], for "about N MB" on the install button.
  int get totalBytes => pins.values.fold(0, (sum, pin) => sum + pin.sizeBytes);

  static Future<Directory> _defaultRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}code_engine');
  }

  /// `<root>/<tool>/<version>`, the directory [pin] unpacks into.
  Future<Directory> installDirFor(CodeEnginePin pin) async {
    final root = await _rootDirectory();
    final sep = Platform.pathSeparator;
    return Directory('${root.path}$sep${pin.tool.id}$sep${pin.version}');
  }

  File _markerIn(Directory dir) => File('${dir.path}${Platform.pathSeparator}.installed');

  /// Whether [pin] is fully installed — its marker is written last, so a
  /// download or unpack that was interrupted never reads as installed. The
  /// executable has to still be there too: antivirus software has been seen
  /// deleting a freshly installed `llama-server.exe` while leaving the rest, and
  /// a marker alone would then report an install that can't run.
  Future<bool> isInstalled(CodeEnginePin pin) async {
    final dir = await installDirFor(pin);
    if (!await _markerIn(dir).exists()) return false;
    return await _findExecutable(dir, pin.tool.executableName) != null;
  }

  /// Installs every pin that isn't already installed, in order, reporting
  /// progress. Throws (as a stream error) on a failed download, a checksum
  /// mismatch, or an archive that doesn't contain the expected executable.
  Stream<CodeEngineProgress> install() async* {
    if (pins.isEmpty) {
      throw StateError('One-click install is only available on Windows x64. Install '
          'llama-server and opencode yourself and put them on PATH.');
    }
    final httpClient = client ?? http.Client();
    try {
      for (final pin in pins.values) {
        if (await isInstalled(pin)) continue;
        yield* _installOne(pin, httpClient);
      }
    } finally {
      if (client == null) httpClient.close();
    }
  }

  Stream<CodeEngineProgress> _installOne(CodeEnginePin pin, http.Client client) async* {
    final dir = await installDirFor(pin);
    final staging = Directory('${dir.path}.partial');
    final zip = File('${staging.path}${Platform.pathSeparator}download.zip');
    final name = pin.tool.id;

    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    try {
      yield CodeEngineProgress('Downloading $name…', fraction: 0);
      final request = http.Request('GET', Uri.parse(pin.url));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw HttpException('Downloading $name failed: HTTP ${response.statusCode} from ${pin.url}');
      }
      final total = (response.contentLength ?? 0) > 0 ? response.contentLength! : pin.sizeBytes;

      final out = zip.openWrite();
      final digestSink = _DigestSink();
      final hasher = sha256.startChunkedConversion(digestSink);
      var received = 0;
      var lastReported = -1.0;
      try {
        await for (final chunk in response.stream) {
          out.add(chunk);
          hasher.add(chunk);
          received += chunk.length;
          final fraction = (received / total).clamp(0.0, 1.0);
          // Throttled: a 60 MB download is thousands of chunks.
          if (fraction - lastReported >= 0.01) {
            lastReported = fraction;
            yield CodeEngineProgress('Downloading $name…', fraction: fraction);
          }
        }
        hasher.close();
      } finally {
        await out.close();
      }

      if (digestSink.value.toString() != pin.sha256) {
        throw StateError(
          'The downloaded $name did not match its expected checksum, so it was '
          "discarded rather than installed. Try again; if it keeps happening the "
          'download is being altered on the way.',
        );
      }

      yield CodeEngineProgress('Unpacking $name…');
      final unpacked = Directory('${staging.path}${Platform.pathSeparator}files');
      await Isolate.run(() => extractFileToDisk(zip.path, unpacked.path));

      final exe = await _findExecutable(unpacked, pin.tool.executableName);
      if (exe == null) {
        throw StateError('${pin.tool.executableName} was not in the downloaded $name archive.');
      }

      // Everything is checked; only now does it replace any earlier attempt.
      await zip.delete();
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.parent.create(recursive: true);
      await unpacked.rename(dir.path);
      await _markerIn(dir).writeAsString(DateTime.now().toIso8601String());
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
    yield CodeEngineProgress('Installed $name.', fraction: 1);
  }

  /// Removes everything this installer put on disk.
  Future<void> uninstall() async {
    final root = await _rootDirectory();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

/// The first file called [name] anywhere under [dir]. Release zips differ in
/// whether they put the executable at the top level or in a subfolder.
Future<File?> _findExecutable(Directory dir, String name) async {
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File && entity.uri.pathSegments.last.toLowerCase() == name.toLowerCase()) {
      return entity;
    }
  }
  return null;
}

/// Captures the single digest a chunked hash conversion emits.
class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
