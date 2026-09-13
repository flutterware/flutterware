/// Where the splash scan reads from.
///
/// The scan is a synchronous walk over a handful of files — two configs, the
/// images they name, the generator's output under `android/`, `ios/` and
/// `web/` — and this is every read it makes, behind one interface.
/// [LiveSplashFiles] is the disk, which is the plugin as it always was.
/// [MemorySplashFiles] is a set of files already in memory, which is what a
/// recording becomes once it is fetched; the scan runs over it unchanged.
/// [RecordingSplashFiles] wraps the live one and remembers every path the
/// scan touched, so a recording holds exactly what the tool read and nothing
/// the recorder guessed at.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

abstract class SplashFiles {
  const SplashFiles();

  /// Done before the first read. The disk needs nothing; a recording fetches
  /// itself here, so that every read below can stay synchronous.
  FutureOr<void> ready() {}

  bool exists(String path);

  bool isDirectory(String path);

  /// The entries directly under [directory], as paths, sorted — an empty list
  /// when it is not there.
  List<String> list(String directory);

  /// The text at [path], or null when it is missing or unreadable.
  String? readString(String path);

  /// The bytes at [path], or null when it is missing or unreadable.
  Uint8List? readBytes(String path);

  /// The first [length] bytes at [path] — fewer when the file is shorter —
  /// or null when it is missing or unreadable.
  Uint8List? readHead(String path, int length);

  /// When [path] was last written and how big it is, or null when it is not
  /// there or cannot be read.
  ({DateTime modified, int size})? stat(String path);
}

/// The disk.
class LiveSplashFiles extends SplashFiles {
  const LiveSplashFiles();

  @override
  bool exists(String path) =>
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

  @override
  bool isDirectory(String path) => FileSystemEntity.isDirectorySync(path);

  @override
  List<String> list(String directory) {
    var dir = Directory(directory);
    if (!dir.existsSync()) return const [];
    try {
      return [for (var entity in dir.listSync()) entity.path]..sort();
    } on FileSystemException {
      return const [];
    }
  }

  @override
  String? readString(String path) {
    var file = File(path);
    if (!file.existsSync()) return null;
    try {
      return file.readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Uint8List? readBytes(String path) {
    var file = File(path);
    if (!file.existsSync()) return null;
    try {
      return file.readAsBytesSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Uint8List? readHead(String path, int length) {
    var file = File(path);
    if (!file.existsSync()) return null;
    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      return handle.readSync(length);
    } on FileSystemException {
      return null;
    } finally {
      handle?.closeSync();
    }
  }

  @override
  ({DateTime modified, int size})? stat(String path) {
    try {
      var s = FileStat.statSync(path);
      if (s.type == FileSystemEntityType.notFound) return null;
      return (modified: s.modified, size: s.size);
    } on FileSystemException {
      return null;
    }
  }
}

/// Files already in memory, keyed by path.
///
/// Paths are matched with `/` whichever separator they were joined with, so
/// a recording made on one platform reads on another; a trailing separator
/// is dropped for the same reason.
class MemorySplashFiles extends SplashFiles {
  MemorySplashFiles({
    Map<String, Uint8List> files = const {},
    Map<String, List<String>?> directories = const {},
    Map<String, ({DateTime modified, int size})> stats = const {},
  }) : _files = {for (var e in files.entries) normalise(e.key): e.value},
       _directories = {
         for (var e in directories.entries)
           normalise(e.key): switch (e.value) {
             null => null,
             var entries => [
               for (var entry in entries) normalise(entry),
             ]..sort(),
           },
       },
       _stats = {for (var e in stats.entries) normalise(e.key): e.value};

  final Map<String, Uint8List> _files;

  /// A directory's entries — null for one that was seen but never listed.
  final Map<String, List<String>?> _directories;

  final Map<String, ({DateTime modified, int size})> _stats;

  static String normalise(String path) {
    var key = path.replaceAll(r'\', '/');
    while (key.length > 1 && key.endsWith('/')) {
      key = key.substring(0, key.length - 1);
    }
    return key;
  }

  @override
  bool exists(String path) =>
      _files.containsKey(normalise(path)) || isDirectory(path);

  @override
  bool isDirectory(String path) => _directories.containsKey(normalise(path));

  @override
  List<String> list(String directory) =>
      _directories[normalise(directory)] ?? const [];

  @override
  String? readString(String path) {
    var bytes = _files[normalise(path)];
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Uint8List? readBytes(String path) => _files[normalise(path)];

  @override
  Uint8List? readHead(String path, int length) {
    var bytes = _files[normalise(path)];
    if (bytes == null) return null;
    return bytes.length <= length
        ? bytes
        : Uint8List.sublistView(bytes, 0, length);
  }

  @override
  ({DateTime modified, int size})? stat(String path) {
    var key = normalise(path);
    if (_stats[key] case var known?) return known;
    var bytes = _files[key];
    if (bytes == null) return null;
    return (
      modified: DateTime.fromMillisecondsSinceEpoch(0),
      size: bytes.length,
    );
  }
}

/// The disk, remembering what was read.
///
/// What `tool/demo/record.dart` runs the scan over: afterwards [files] is
/// every file the scan opened or statted and found, [directories] every
/// directory it listed with what it saw there — and every directory it saw
/// as an entry, with no listing — which is exactly the set a recording has
/// to carry for the same scan to give the same answer.
class RecordingSplashFiles extends SplashFiles {
  RecordingSplashFiles([this.inner = const LiveSplashFiles()]);

  final SplashFiles inner;

  /// Every file whose contents or stat the scan asked for, and found.
  final files = <String>{};

  /// Every directory the scan listed, with what it saw, and every one it
  /// only asked about, with null.
  final directories = <String, List<String>?>{};

  /// A path the scan asked about, not read: only its being a directory is
  /// worth keeping — a file merely listed is skipped by name and never
  /// opened, and copying it would carry files the scan does not read.
  void _asked(String path) {
    if (inner.isDirectory(path)) directories.putIfAbsent(path, () => null);
  }

  /// A path the scan read: kept whole.
  void _read(String path) {
    _asked(path);
    if (!inner.isDirectory(path) && inner.exists(path)) files.add(path);
  }

  @override
  bool exists(String path) {
    _asked(path);
    return inner.exists(path);
  }

  @override
  bool isDirectory(String path) {
    _asked(path);
    return inner.isDirectory(path);
  }

  @override
  List<String> list(String directory) {
    var entries = inner.list(directory);
    if (inner.isDirectory(directory)) {
      directories[directory] = entries;
      for (var entry in entries) {
        _asked(entry);
      }
    }
    return entries;
  }

  @override
  String? readString(String path) {
    _read(path);
    return inner.readString(path);
  }

  @override
  Uint8List? readBytes(String path) {
    _read(path);
    return inner.readBytes(path);
  }

  @override
  Uint8List? readHead(String path, int length) {
    _read(path);
    return inner.readHead(path, length);
  }

  @override
  ({DateTime modified, int size})? stat(String path) {
    _read(path);
    return inner.stat(path);
  }
}
