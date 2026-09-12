/// The splash plugin over a recording: the live core and the live panel,
/// handed the files the scan read, fetched from the recording into memory
/// before the scan runs — the scan itself is synchronous and unchanged.
///
/// `tool/demo/record.dart` runs the scan over the disk through
/// `RecordingSplashFiles` and keeps every file it touched and every directory
/// it listed. [RecordedSplashFiles] reads that index and those files back on
/// [ready], spells each under the recorded project's root, and is then a
/// [MemorySplashFiles] the scan walks as it would walk a disk. The panel's
/// pictures come from the same recording, by the path the scan handed it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../splash/model/files.dart';
import '../splash/ui/splash_render.dart' show SplashImage;
import 'recording.dart';

/// Where the splash scan reads from when the project is a recording —
/// `SplashCore(files: …)`.
class RecordedSplashFiles extends SplashFiles {
  RecordedSplashFiles(this.recording, {this.packagePath = '.'});

  final Recording recording;
  final String packagePath;

  MemorySplashFiles? _loaded;
  Future<void>? _loading;

  /// The scan's root, as the recorded workspace spells the package.
  String get _root => packagePath == '.'
      ? recordedProjectRoot
      : '$recordedProjectRoot/$packagePath';

  @override
  Future<void> ready() => _loading ??= _load();

  Future<void> _load() async {
    // Through `Future.value`, for the reason `recordedIconScanner` gives: a
    // synchronous end must still resume this function on a microtask.
    var text = await Future.value(
      recording.readString(recordedSplashIndexPath(packagePath)),
    );
    if (text == null) {
      throw StateError(
        'This recording has no splash files for "$packagePath" '
        '(looked for ${recordedSplashIndexPath(packagePath)}).',
      );
    }
    var json = jsonDecode(text) as Map<String, Object?>;
    var files = <String, Uint8List>{};
    var stats = <String, ({DateTime modified, int size})>{};
    for (var entry in (json['files'] as Map? ?? const {}).entries) {
      var relative = '${entry.key}';
      var facts = (entry.value as Map).cast<String, Object?>();
      var bytes = await Future.value(
        recording.readBytes(recordedSplashFilePath(packagePath, relative)),
      );
      if (bytes == null) continue;
      var path = '$_root/$relative';
      files[path] = bytes;
      stats[path] = (
        modified:
            DateTime.tryParse('${facts['modified']}') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        size: facts['size'] as int? ?? bytes.length,
      );
    }
    var directories = <String, List<String>?>{
      for (var entry in (json['directories'] as Map? ?? const {}).entries)
        _absolute('${entry.key}'): switch (entry.value) {
          List entries => [for (var name in entries) _absolute('$name')],
          _ => null,
        },
    };
    _loaded = MemorySplashFiles(
      files: files,
      directories: directories,
      stats: stats,
    );
  }

  /// A recorded path is package-relative; `.` is the root itself.
  String _absolute(String relative) =>
      relative == '.' ? _root : '$_root/$relative';

  MemorySplashFiles get _files =>
      _loaded ??
      (throw StateError('RecordedSplashFiles read before `ready()`.'));

  @override
  bool exists(String path) => _files.exists(path);

  @override
  bool isDirectory(String path) => _files.isDirectory(path);

  @override
  List<String> list(String directory) => _files.list(directory);

  @override
  String? readString(String path) => _files.readString(path);

  @override
  Uint8List? readBytes(String path) => _files.readBytes(path);

  @override
  Uint8List? readHead(String path, int length) => _files.readHead(path, length);

  @override
  ({DateTime modified, int size})? stat(String path) => _files.stat(path);
}

/// The pictures of a recorded scan — `SplashPlugin(image: …)`. The scan
/// spelled every path under the recorded root, and the recording holds the
/// file at the same relative path.
SplashImage recordedSplashImage(
  Recording recording, {
  String packagePath = '.',
}) {
  var root = packagePath == '.'
      ? recordedProjectRoot
      : '$recordedProjectRoot/$packagePath';
  return (absolutePath) {
    var path = MemorySplashFiles.normalise(absolutePath);
    var relative = path.startsWith('$root/')
        ? path.substring(root.length + 1)
        : path;
    return recording.encodedImage(
      recordedSplashFilePath(packagePath, relative),
    );
  };
}
