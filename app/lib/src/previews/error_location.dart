import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package_config_locator.dart';

/// Which of an error's frames to send a reader to.
///
/// The guest keeps every frame outside the framework and does not choose among
/// them, because choosing is a question about the project and the project is
/// known here. The first frame in one of its own packages wins — the theme
/// that called into a font package, rather than the font package — and failing
/// that the first frame at all, because a dependency's name is still the
/// fastest way to the cause.
///
/// What flutterware ran the entry under is never the answer: its own library,
/// and the wrappers it generated under a `build/` directory.
class ErrorLocator {
  ErrorLocator({required this.worktree, this.ownPackages = const {}});

  /// The locator for a package in [worktree]. Its own packages are the ones
  /// its resolution places inside [worktree] — itself, and its workspace
  /// siblings — as the package config declares them.
  factory ErrorLocator.forPackage(
    String packageRoot, {
    required String worktree,
  }) => ErrorLocator(
    worktree: worktree,
    ownPackages: _packagesWithin(packageRoot, worktree),
  );

  final String worktree;

  /// Package names whose `package:` frames count as the project's.
  final Set<String> ownPackages;

  /// Where [frames] point a reader, or null when they point nowhere.
  ///
  /// A `package:` frame is kept as it is; a `file:` one is made relative to
  /// [worktree], which is how every other source location in a reply reads.
  String? locate(List<String> frames) {
    var candidates = [
      for (var frame in frames)
        if (!_isScaffolding(frame)) frame,
    ];
    if (candidates.isEmpty) return null;
    var chosen = candidates.firstWhere(_isOwn, orElse: () => candidates.first);
    if (_fileOf(chosen) case (var path, var position)) {
      return _isWithin(path)
          ? '${p.split(p.relative(path, from: worktree)).join('/')}$position'
          : '$path$position';
    }
    return chosen;
  }

  bool _isOwn(String frame) {
    if (_packageOf(frame) case var package?) {
      return ownPackages.contains(package);
    }
    return switch (_fileOf(frame)) {
      (var path, _) => _isWithin(path),
      null => false,
    };
  }

  bool _isScaffolding(String frame) {
    if (_packageOf(frame) == 'flutterware') return true;
    if (_fileOf(frame) case (var path, _) when _isWithin(path)) {
      var segments = p.split(p.relative(path, from: worktree));
      return segments.contains('build') || segments.contains('.dart_tool');
    }
    return false;
  }

  bool _isWithin(String path) => p.isWithin(worktree, path);

  static String? _packageOf(String frame) => frame.startsWith('package:')
      ? frame.substring('package:'.length).split('/').first
      : null;

  /// The file a `file:` frame names, and the `:line:column` after it — which
  /// is not part of the URI, and parsing it as one would read it as more path.
  static (String, String)? _fileOf(String frame) {
    if (!frame.startsWith('file:')) return null;
    var position = RegExp(r'(:\d+){1,2}$').firstMatch(frame);
    var uri = position == null ? frame : frame.substring(0, position.start);
    try {
      return (p.fromUri(Uri.parse(uri)), position?.group(0) ?? '');
    } on FormatException {
      return null;
    }
  }

  static Set<String> _packagesWithin(String packageRoot, String worktree) {
    var config = findPackageConfig(packageRoot);
    if (config == null) return const {};
    try {
      var json = jsonDecode(File(config).readAsStringSync());
      var packages = json is Map ? json['packages'] : null;
      if (packages is! List) return const {};
      var directory = p.dirname(config);
      bool inside(String rootUri) {
        var root = p.normalize(
          p.join(directory, p.fromUri(Uri.parse(rootUri))),
        );
        return p.equals(worktree, root) || p.isWithin(worktree, root);
      }

      return {
        for (var package in packages)
          if (package case {'name': String name, 'rootUri': String rootUri})
            if (inside(rootUri)) name,
      };
    } on FormatException {
      return const {};
    } on FileSystemException {
      return const {};
    }
  }
}
