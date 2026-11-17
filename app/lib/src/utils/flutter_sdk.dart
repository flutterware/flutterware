import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../constants.dart';

class FlutterSdkPath {
  final String root;

  FlutterSdkPath(String path) : root = p.canonicalize(path);

  /// The SDK whose `bin/flutter` is [flutter].
  factory FlutterSdkPath.ofFlutter(String flutter) =>
      FlutterSdkPath(p.dirname(p.dirname(flutter)));

  factory FlutterSdkPath.fromJson(Map<String, dynamic> json) =>
      FlutterSdkPath(json['root'] as String);

  static Future<FlutterSdkPath?> tryFind(String path) async {
    if (await FileSystemEntity.isDirectory(path)) {
      var dir = Directory(path);
      while (await dir.exists()) {
        var sdk = FlutterSdkPath(dir.path);
        if (await isValid(sdk)) {
          return sdk;
        } else {
          var parent = dir.parent;
          if (parent.path == dir.path) return null;
          dir = parent;
        }
      }
    } else if (await FileSystemEntity.isFile(path)) {
      return tryFind(File(path).parent.path);
    }
    return null;
  }

  Map<String, dynamic> toJson() => {'root': root};

  String get binDir => p.join(root, 'bin');

  String get flutter =>
      p.join(binDir, 'flutter${Platform.isWindows ? '.bat' : ''}');

  String get dart => p.join(binDir, 'dart${Platform.isWindows ? '.bat' : ''}');

  @override
  bool operator ==(other) => other is FlutterSdkPath && other.root == root;

  @override
  int get hashCode => root.hashCode;

  @override
  String toString() => 'Flutter SDK ($root)';

  static Future<bool> isValid(FlutterSdkPath sdk) async {
    return File(sdk.flutter).existsSync() && File(sdk.dart).existsSync();
  }

  /// Which Flutter this is — `3.48.0-0.2.pre` — as the SDK itself records it,
  /// or null when it records nothing yet.
  String? get version => _versionFile()?['frameworkVersion'] as String?;

  /// The arguments that keep `flutter build web` from writing a caching
  /// service worker: `--pwa-strategy=none` before Flutter 3.51, and nothing
  /// from 3.51 on, which writes no worker and fails a build that passes the
  /// flag. An SDK that records no version gets nothing too: a worker the page
  /// does not need is better than a build that fails.
  List<String> get webBuildWithoutServiceWorker {
    var recorded = version;
    if (recorded == null) return const [];
    try {
      return Version.parse(recorded) < _pwaStrategyRemoved
          ? const ['--pwa-strategy=none']
          : const [];
    } on FormatException {
      return const [];
    }
  }

  static final _pwaStrategyRemoved = Version(3, 51, 0, pre: '0');

  /// What this SDK draws like, for a cache key: its framework and engine
  /// revisions, or [root] when it has not recorded them.
  ///
  /// Not the root, which is what keys used to carry. A path names where an
  /// SDK sits rather than which one it is, and a CI image keeps Flutter at the
  /// same path across every upgrade — so a shot cache restored onto the next
  /// image served pictures the previous engine had drawn.
  String get identity {
    var file = _versionFile();
    var framework = file?['frameworkRevision'];
    var engine = file?['engineRevision'];
    if (framework is! String || engine is! String) return root;
    return '$framework/$engine';
  }

  /// `bin/cache/flutter.version.json`, which the tool writes the first time it
  /// runs in this SDK. Every SDK a comparison runs under has run the tool
  /// already — it is what resolved the checkouts.
  Map<String, Object?>? _versionFile() {
    var file = File(p.join(root, 'bin', 'cache', 'flutter.version.json'));
    try {
      var json = jsonDecode(file.readAsStringSync());
      return json is Map<String, Object?> ? json : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// The SDK this project runs under: **the one that started us**.
  ///
  /// Not discovered, and that is the whole rule. `dart run flutterware` arrives
  /// through the user's own `dart` — fvm, mise, asdf, or a path they typed —
  /// and choosing it is how they say which SDK this project uses. Reading a pin
  /// file, a version manager's cache or `FLUTTER_HOME` would be flutterware
  /// answering that question on their behalf, and every one of those answers
  /// can disagree with the interpreter that is actually running.
  ///
  /// Two spellings of the one signal:
  ///
  /// 1. [dartExecutableEnvironmentKey], recorded by the launcher when it spawns
  ///    the CLI — the only one that survives the hop into a compiled binary.
  /// 2. [Platform.resolvedExecutable], when this process *is* running under the
  ///    dart in question: `dart run flutterware_app:fw`, and the test harness.
  ///
  /// Null when neither answers, which is a compiled Flutter app: there
  /// `resolvedExecutable` is the app binary and no SDK sits above it. Those
  /// entry points are *told* instead, through [flutterSdkDefineKey] — see
  /// `main.dart`. Nothing here guesses on their behalf.
  ///
  /// [environment] exists so a test can ask about an environment it built
  /// rather than the one it happens to run in.
  static Future<FlutterSdkPath?> findSdk({
    Map<String, String>? environment,
  }) async {
    var env = environment ?? Platform.environment;

    var recorded = env[dartExecutableEnvironmentKey];
    if (recorded != null && recorded.isNotEmpty) {
      var sdk = await tryFind(recorded);
      if (sdk != null) return sdk;
    }

    return tryFind(Platform.resolvedExecutable);
  }
}

class FlutterSdk {
  final FlutterSdkPath path;

  FlutterSdk(this.path);

  factory FlutterSdk.fromJson(Map<String, dynamic> json) =>
      FlutterSdk(FlutterSdkPath.fromJson(json));

  Map<String, dynamic> toJson() => path.toJson();

  String get flutter => path.flutter;

  String get dart => path.dart;

  @override
  bool operator ==(other) => other is FlutterSdk && other.path == path;

  @override
  int get hashCode => path.hashCode;
}
