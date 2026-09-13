/// The bytes behind a file in the delta, for the bodies a diff cannot draw:
/// an image, a rendered markdown file, an untracked file's own lines.
///
/// Two sides, two sources. The **new** side is the working tree — right for
/// added, modified and untracked alike, because the patch's right side *is*
/// the working tree. The **old** side is `git cat-file` against the revision
/// the delta is measured from.
///
/// Pure Dart, so the kind detection and the cache policy are testable without
/// pumping a widget. The disk is behind [ChangesFiles], so a recording can
/// stand in for it.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'changes_files.dart';
import 'changes_probe.dart';

/// What the right pane can draw for a file, decided by its extension.
///
/// [text] is the default and means *the diff* for a tracked file and *the
/// lines themselves* for an untracked one. [svg] is separate from [image]
/// because an SVG is text: it diffs, and rendering it is a view onto the same
/// bytes rather than the only thing left to do with them.
enum FileBodyKind { text, markdown, image, svg }

/// Decided by extension alone. Content sniffing is deliberately not here: the
/// kind picks which *viewer* opens, and a viewer handed bytes it cannot decode
/// says so in place — see `looksBinary` for the one sniff that is worth doing.
FileBodyKind fileBodyKind(String path) {
  var dot = path.lastIndexOf('.');
  if (dot < 0 || dot < path.lastIndexOf('/')) return FileBodyKind.text;
  return switch (path.substring(dot + 1).toLowerCase()) {
    'md' || 'markdown' => FileBodyKind.markdown,
    // What Flutter's own codecs decode. No avif/heic: they come back as an
    // error row, which is worse than the binary notice they replace.
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' => FileBodyKind.image,
    'svg' => FileBodyKind.svg,
    _ => FileBodyKind.text,
  };
}

/// Which face of the file the body shows. Only kinds with two faces get the
/// header toggle; for the rest the default is all there is.
enum FileBodyView { source, rendered }

/// Whether [bytes] read as binary — git's own heuristic, a NUL in the first
/// 8000 bytes. For the untracked file no patch has already classified.
bool looksBinary(Uint8List bytes) {
  var end = math.min(bytes.length, 8000);
  for (var i = 0; i < end; i++) {
    if (bytes[i] == 0) return true;
  }
  return false;
}

/// One side's content, or the reason there is none. Every case is drawn in
/// place — a viewer that opens to silence reads as a bug in the viewer.
sealed class FileContent {
  const FileContent();
}

final class FileBytes extends FileContent {
  const FileBytes(this.bytes);

  final Uint8List bytes;

  String get text => const Utf8Decoder(allowMalformed: true).convert(bytes);
}

/// Nothing there: a path deleted from the working tree, or a revision that
/// never had it.
final class FileMissing extends FileContent {
  const FileMissing();
}

/// Present but past the bound the caller set. Carries the size so the notice
/// can say what it refused rather than that it refused.
final class FileTooLarge extends FileContent {
  const FileTooLarge(this.length);

  final int length;
}

/// Reads and remembers file content for one worktree's changes screen.
///
/// The key is everything that can change the answer, so nothing ever
/// invalidates: the disk side is keyed by mtime and size, which an edit
/// changes and a re-probe does not; the revision side is keyed by the
/// revision, which is immutable. This is what makes the viewer safe against
/// the trap the screen's own refresh cannot see — an agent overwriting an
/// *untracked* image changes neither the patch bytes nor the untracked list,
/// so `ChangeSet.sameAnswerAs` rightly says the delta did not move, and only
/// a stat notices the file did.
class FileContentStore {
  FileContentStore(
    this.worktreePath, {
    ChangesProbe? probe,
    this.files = const LiveChangesFiles(),
  }) : _probe = probe ?? ChangesProbe();

  final String worktreePath;
  final ChangesProbe _probe;

  /// The working tree — the new side of everything here.
  final ChangesFiles files;

  /// Insertion-ordered, re-inserted on hit — an LRU of futures.
  ///
  /// Bounded by entry count rather than bytes: one screen shows at most two
  /// sides at a time, and the bound exists so flipping through a branch's
  /// screenshots does not accumulate all of them.
  final _cache = <String, Future<FileContent>>{};

  static const _capacity = 16;

  /// The working-tree side. Stat first: the refusal of a huge file must not
  /// cost reading it, and the stat is what keys the cache.
  Future<FileContent> onDisk(String path, {required int maxBytes}) async {
    var file = '$worktreePath/$path';
    var stat = await files.stat(file);
    if (stat == null) return const FileMissing();
    if (stat.size > maxBytes) return FileTooLarge(stat.size);
    return _remember(
      'disk:$path:${stat.modified.microsecondsSinceEpoch}:${stat.size}',
      () async {
        var bytes = await files.readBytes(file);
        return bytes == null ? const FileMissing() : FileBytes(bytes);
      },
    );
  }

  /// The other side: [path] as it was at [revision].
  Future<FileContent> atRevision(
    String revision,
    String path, {
    required int maxBytes,
  }) => _remember('rev:$revision:$path:$maxBytes', () async {
    var size = await _probe.blobSize(worktreePath, revision, path);
    if (size == null) return const FileMissing();
    if (size > maxBytes) return FileTooLarge(size);
    var bytes = await _probe.blobBytes(worktreePath, revision, path);
    return bytes == null ? const FileMissing() : FileBytes(bytes);
  });

  Future<FileContent> _remember(
    String key,
    Future<FileContent> Function() load,
  ) {
    if (_cache.remove(key) case var hit?) return _cache[key] = hit;
    var loading = load();
    _cache[key] = loading;
    while (_cache.length > _capacity) {
      _cache.remove(_cache.keys.first);
    }
    return loading;
  }
}
