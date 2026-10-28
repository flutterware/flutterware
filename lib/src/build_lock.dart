import 'dart:io';

/// One writer at a time in a build tree that several processes share.
///
/// The tree under `~/.flutterware/<hash>` is one copy per flutterware version
/// and SDK **per machine**, reached by every project that depends on that
/// version under that SDK. That
/// is deliberate — it is what makes the second project's first run free — but it
/// means two cold invocations on one machine unpack into the same directory and
/// then run `dart build cli -o` against the same output path.
///
/// What that costs is not a slower build, it is a corrupt one, and it is
/// reproducible: two concurrent `dart build cli` runs into one output directory
/// fail roughly two times in three. Both write `bundle/bin/fw`, and whichever
/// loses lands on one of two errors — `install_name_tool` refusing to add
/// `@executable_path/..` to a binary that already has it, because the winner
/// just added it, or a raw `writeFrom failed … Input/output error` from
/// appending a snapshot to a file being replaced underneath. A developer
/// machine never sees either, because it never has two *cold* runs at once;
/// a CI runner with parallel jobs has nothing but.
///
/// Blocking is deliberate. The loser is not looking for something else to do —
/// it wants exactly the artifacts the winner is producing, so waiting them out
/// and then finding the work already done is the desired outcome.
///
/// No in-process queue, unlike `BaseCheckout.ensure`, which needs one because
/// the OS lock is advisory per *process* and two `ensure` calls inside one GUI
/// would both pass it. This is called once per process, before anything else
/// runs, so there is no second caller to serialize.
Future<T> withBuildLock<T>(
  String lockFile,
  Future<T> Function() body, {
  void Function()? onWait,
}) async {
  var file = File(lockFile);
  file.parent.createSync(recursive: true);
  // Beside the tree rather than inside it: the tree is deleted and rewritten by
  // the very operation this guards, and a lock that a copy can remove is not a
  // lock. Nothing reads the file — the handle is the whole point of it.
  var handle = file.openSync(mode: FileMode.write);
  try {
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      // Only now is there anything to say. Announcing the wait before trying
      // would put a line in front of every warm run to report that nothing
      // happened.
      onWait?.call();
      await handle.lock(FileLock.blockingExclusive);
    }
    return await body();
  } finally {
    // Closing releases the lock, including on the paths out of here that do not
    // return — an `exit` inside [body] hands it back to the OS.
    handle.closeSync();
  }
}
