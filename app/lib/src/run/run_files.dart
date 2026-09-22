import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The files a run is made of: its handle, its launcher's log, its journal and
/// the pictures the journal points at, the device cache and the flag memory.
///
/// Every one of them is written once by the tool and then only read, which is
/// what makes a run recordable at all: [DiskRunFiles] is the machine, and a
/// recording answers the same reads by the same paths. The run plugin reads
/// through this and never through `File`, so the cockpit is the same code
/// over either.
///
/// Synchronous, because the readers are — a log tail reads by offset on a
/// timer, and the Steps tab decides whether a step has a picture while it
/// builds. A store that has to fetch first says so in [ready].
///
/// Pure Dart: the core runs under `fw` as well as under the studio.
abstract class RunFiles {
  const RunFiles();

  /// Completes once every read below can answer. The disk always can.
  Future<void> get ready;

  /// The bytes of [path] from [start] on, or null when there is no such file.
  Uint8List? readBytes(String path, {int start = 0});

  /// How many bytes [path] holds, or null when there is no such file.
  int? lengthOf(String path);

  /// The files directly inside [directory], as paths. Empty when there is no
  /// such directory.
  List<String> list(String directory);

  /// Writes [text] to [path], creating what it needs to.
  void writeString(String path, String text);

  /// Fires whenever [path] may have changed. Never, for files that cannot.
  Stream<void> changes(String path);

  /// The text of [path], or null when there is no such file. Tolerant of a
  /// half-written character, like every reader of a file still being
  /// appended to has to be.
  String? readString(String path) {
    var bytes = readBytes(path);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  bool exists(String path) => lengthOf(path) != null;
}

/// The machine's own files.
class DiskRunFiles extends RunFiles {
  const DiskRunFiles();

  @override
  Future<void> get ready => Future.value();

  @override
  Uint8List? readBytes(String path, {int start = 0}) {
    try {
      var file = File(path);
      if (start == 0) return file.readAsBytesSync();
      var handle = file.openSync();
      try {
        var length = handle.lengthSync();
        if (start >= length) return Uint8List(0);
        handle.setPositionSync(start);
        return handle.readSync(length - start);
      } finally {
        handle.closeSync();
      }
    } on FileSystemException {
      return null;
    }
  }

  @override
  int? lengthOf(String path) {
    try {
      return File(path).lengthSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  List<String> list(String directory) {
    try {
      return [
        for (var entity in Directory(directory).listSync())
          if (entity is File) entity.path,
      ];
    } on FileSystemException {
      return const [];
    }
  }

  @override
  void writeString(String path, String text) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  /// A watch *and* a poll. The watch is what makes a change land in 50ms; the
  /// poll is there because a directory watch is not offered everywhere and
  /// does not survive every kind of write, and a log that stopped updating is
  /// worse than a log that updates a little late. When the watch is up the
  /// poll drops to a backstop interval.
  ///
  /// This is what lets a panel showing a log or a journal re-read it on a
  /// change rather than from `build`, which runs on every probe and every
  /// frame of any animation above it.
  @override
  Stream<void> changes(String path) {
    StreamSubscription<FileSystemEvent>? watch;
    Timer? debounce;
    Timer? poll;
    // Closed by nothing: the stream is single-subscription, and cancelling it
    // is what tears the watch and the poll down.
    // ignore: close_sinks
    late StreamController<void> controller;
    controller = StreamController<void>(
      onListen: () {
        var directory = File(path).parent;
        if (directory.existsSync()) {
          watch = directory.watch().listen((event) {
            if (!event.path.startsWith(path)) return;
            debounce?.cancel();
            debounce = Timer(
              const Duration(milliseconds: 50),
              () => controller.add(null),
            );
          }, onError: (_) {});
        }
        poll = Timer.periodic(
          watch != null
              ? const Duration(seconds: 2)
              : const Duration(milliseconds: 700),
          (_) => controller.add(null),
        );
      },
      onCancel: () async {
        debounce?.cancel();
        poll?.cancel();
        await watch?.cancel();
      },
    );
    return controller.stream;
  }
}
