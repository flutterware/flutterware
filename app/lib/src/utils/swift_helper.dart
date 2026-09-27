import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../constants.dart';
import 'run_dir.dart';

/// A Swift program the studio ships as source beside its Dart code and
/// compiles on first use: what reaches the macOS APIs a Flutter process
/// cannot — the accessibility tree, WebKit rendering off screen.
///
/// Compiled with `xcrun swiftc` into flutterware's own directory, keyed by a
/// hash of the source, so an edit to the Swift lands on the next call and a
/// machine that already compiled it pays nothing. Not in the checkout: a
/// hosted install's package directory is not reliably writable.
class SwiftHelper {
  const SwiftHelper(this.name, this.sourcePath);

  /// The binary's name, and the prefix of its cached file.
  final String name;

  /// Where its source is, relative to the `flutterware_app` package:
  /// `lib/src/run/native/ax_helper.swift`.
  final String sourcePath;

  /// The compiled helper's path, compiling it if this source never was; null
  /// off macOS, or when the source cannot be found. [root] is the
  /// `flutterware_app` package root, for a caller that knows it — a Flutter
  /// process, which cannot resolve its own package. Throws a
  /// [SwiftHelperError] when it does not compile.
  Future<String?> ensure({String? root, String? sourceOverride}) async {
    if (!Platform.isMacOS) return null;
    var source = sourceOverride ?? await _source(root);
    if (source == null) return null;
    var digest = sha1.convert(utf8.encode(source)).toString().substring(0, 12);
    var binary = File(p.join(flutterwareDir(), 'native', '$name-$digest'));
    if (binary.existsSync()) return binary.path;

    var scratch = Directory(p.join(binary.parent.path, 'build-$name-$digest'))
      ..createSync(recursive: true);
    try {
      var swift = File(p.join(scratch.path, '$name.swift'))
        ..writeAsStringSync(source);
      var result = await Process.run('xcrun', [
        'swiftc',
        '-O',
        swift.path,
        '-o',
        binary.path,
      ]);
      if (result.exitCode != 0 || !binary.existsSync()) {
        throw SwiftHelperError('${result.stderr}'.trim());
      }
      return binary.path;
    } on ProcessException catch (e) {
      throw SwiftHelperError('$e', missingTools: true);
    } finally {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    }
  }

  /// The source, from [root] when the caller knows it, and otherwise found
  /// two ways because the two ways cover different lives of this code. `Isolate.resolvePackageUri` is exact, and it is what runs
  /// under the MCP server and the tests, which execute from source. It also
  /// **throws in an AOT binary** — which is what `fw` is — so the compiled
  /// CLI falls back to the app directory the launcher already tells it about.
  Future<String?> _source(String? root) async {
    if (root != null) {
      var file = File(p.join(root, sourcePath));
      if (file.existsSync()) return file.readAsStringSync();
    }
    try {
      var uri = await Isolate.resolvePackageUri(
        Uri.parse(
          'package:flutterware_app/${sourcePath.replaceFirst('lib/', '')}',
        ),
      );
      if (uri != null) {
        var file = File.fromUri(uri);
        if (file.existsSync()) return file.readAsStringSync();
      }
    } on UnsupportedError {
      // AOT. The environment knows where the app package is.
    }
    for (var key in const [appToolPathKey, appPathEnvironmentKey]) {
      var root = Platform.environment[key];
      if (root == null || root.isEmpty) continue;
      var file = File(p.join(root, sourcePath));
      if (file.existsSync()) return file.readAsStringSync();
    }
    return null;
  }
}

/// A helper that did not compile: [message] is the compiler's, or — with
/// [missingTools] — the Xcode command line tools are not there to compile it.
class SwiftHelperError implements Exception {
  SwiftHelperError(this.message, {this.missingTools = false});

  final String message;
  final bool missingTools;

  @override
  String toString() => message;
}
