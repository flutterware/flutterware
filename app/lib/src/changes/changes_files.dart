/// What the changes screen reads off the working tree, apart from git.
///
/// Two reads, and both are the disk side of a delta rather than git's: the
/// stat that stamps an untracked file, and the bytes behind a body a diff
/// cannot draw — an image's new side, a rendered markdown file, an untracked
/// file's own lines. Everything else the screen shows comes out of the patch.
///
/// The seam exists for the studio's recordings, which have a git tape and a
/// copied file or two and no working tree. Paths are absolute, spelled the
/// way the probe spells them: `<worktree>/<path>`.
///
/// Pure Dart apart from `dart:io` in the live one — `fw` links this.
library;

import 'dart:io';
import 'dart:typed_data';

/// One file's stat, as much of it as a stamp or a size check needs.
typedef FileFacts = ({int size, DateTime modified});

abstract class ChangesFiles {
  const ChangesFiles();

  /// [path]'s size and time, or null when there is no such file.
  Future<FileFacts?> stat(String path);

  /// [path]'s bytes, or null when it went between the stat and the read.
  Future<Uint8List?> readBytes(String path);
}

/// The disk.
class LiveChangesFiles extends ChangesFiles {
  const LiveChangesFiles();

  @override
  Future<FileFacts?> stat(String path) async {
    try {
      var stat = await File(path).stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      return (size: stat.size, modified: stat.modified);
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<Uint8List?> readBytes(String path) async {
    try {
      return await File(path).readAsBytes();
    } on FileSystemException {
      // Deleted between the stat and the read — the next refresh will say
      // so; this load just must not throw into a widget.
      return null;
    }
  }
}
