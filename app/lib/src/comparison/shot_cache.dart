import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'closure.dart';

/// Rendered pictures, filed by what made them.
///
/// Shared across every worktree on the machine and every comparison run,
/// because the key already says everything about a picture: five agents
/// branched off one commit render its previews once between them.
///
/// The base checkout is a build fixture; this is what persists. A
/// comparison materialises a base worktree, renders from it, and may throw the
/// worktree away — the shots outlive it, and the next comparison against that
/// commit renders nothing at all.
class ShotCache {
  ShotCache(this.root);

  /// `~/.flutterware/shots` in production; a temp directory in a test.
  final String root;

  late final ClosureMemo memo = ClosureMemo(p.join(root, 'closures'));

  /// Whether [key] has already been rendered.
  bool has(String key) => File(_pathFor(key)).existsSync();

  /// The picture filed under [key], or null when nothing is.
  ///
  /// Touches the file on the way past, which is what makes [sweep]'s eviction
  /// a real LRU rather than a first-in-first-out. Without it the entries that
  /// survive would be the most recently *written* ones — and this cache's
  /// whole point is the opposite: a base commit's shots are written once and
  /// then hit by every comparison against it for weeks, so they are exactly
  /// what a write-ordered sweep would throw away first. One `utimes` against a
  /// multi-megabyte read is not a cost worth measuring.
  Uint8List? read(String key) {
    var file = File(_pathFor(key));
    if (!file.existsSync()) return null;
    var bytes = file.readAsBytesSync();
    try {
      file.setLastModifiedSync(DateTime.now());
    } on FileSystemException {
      // A read-only store, or a file another process just swept. The bytes are
      // in hand either way, and refreshing an age is not worth an exception.
    }
    return bytes;
  }

  ShotRecord? meta(String key) {
    var file = File('${_pathFor(key)}.json');
    if (!file.existsSync()) return null;
    try {
      var json = jsonDecode(file.readAsStringSync());
      return json is Map<String, Object?> ? ShotRecord.fromJson(json) : null;
    } on FormatException {
      return null;
    }
  }

  /// Files [bytes] under [key].
  ///
  /// Written to a temporary name and renamed, because a comparison can be
  /// killed at any moment and a half-written picture under a content key is a
  /// lie that never expires: every later run would find the key present and
  /// serve the truncated file. Rename is atomic on every filesystem this runs
  /// on.
  void write(String key, Uint8List bytes, ShotRecord record) {
    var path = _pathFor(key);
    Directory(p.dirname(path)).createSync(recursive: true);
    var staging = File('$path.part');
    staging.writeAsBytesSync(bytes, flush: true);
    File('$path.json').writeAsStringSync(jsonEncode(record.toJson()));
    staging.renameSync(path);
  }

  /// Files the picture already on disk at [source] under [key], by moving it
  /// there — or, where it cannot be moved, by writing [bytes].
  ///
  /// For a frame a replay has just written: copying megabytes that are about
  /// to be deleted is the one cost a move does not have. A rename is atomic,
  /// so the key never names a half-moved file; across filesystems it fails,
  /// and [write] is the answer to that.
  void adopt(String key, File source, Uint8List bytes, ShotRecord record) {
    var path = _pathFor(key);
    Directory(p.dirname(path)).createSync(recursive: true);
    File('$path.json').writeAsStringSync(jsonEncode(record.toJson()));
    try {
      source.renameSync(path);
    } on FileSystemException {
      write(key, bytes, record);
    }
  }

  /// [adopt], for a caller that never read the picture into memory: where the
  /// move fails, the file is copied rather than written from bytes.
  void adoptFile(String key, String sourcePath, ShotRecord record) {
    var source = File(sourcePath);
    var path = _pathFor(key);
    Directory(p.dirname(path)).createSync(recursive: true);
    File('$path.json').writeAsStringSync(jsonEncode(record.toJson()));
    try {
      source.renameSync(path);
    } on FileSystemException {
      source.copySync('$path.part').renameSync(path);
    }
  }

  /// Where [key]'s picture lives, whether or not anything is there.
  String pathOf(String key) => _pathFor(key);

  /// The tree taken off the same frame, filed beside it.
  ///
  /// Same key, because it is the same render: a tree that came from a
  /// different build than the picture is the exact thing
  /// `HeadlessCatalog.observe`'s one-render rule exists to prevent, and
  /// splitting the key here would reintroduce it through the back door.
  void writeTree(String key, Map<String, Object?> tree) {
    var path = '${_pathFor(key)}.tree.json';
    Directory(p.dirname(path)).createSync(recursive: true);
    File(path).writeAsStringSync(jsonEncode(tree));
  }

  /// The tree filed under [key], or null when nothing is.
  ///
  /// Touched on the way past, for the reason [read] touches. A preview's tree
  /// sits beside its bytes and shares their age, but a replayed step's tree is
  /// an entry of its own: left untouched, it is the oldest thing in the store
  /// on the day the store runs over [sweep]'s cap, and goes first while the
  /// frames and the list that name it survive.
  Map<String, Object?>? readTree(String key) {
    var file = File('${_pathFor(key)}.tree.json');
    if (!file.existsSync()) return null;
    Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
    try {
      file.setLastModifiedSync(DateTime.now());
    } on FileSystemException {
      // Read-only, or swept a moment ago. The tree is in hand.
    }
    return json is Map<String, Object?> ? json : null;
  }

  /// Two levels of fan-out, as every content-addressed store does it: a
  /// hundred thousand shots in one directory is a directory listing nothing
  /// wants to do.
  String _pathFor(String key) =>
      p.join(root, key.substring(0, 2), key.substring(2, 4), key);

  /// Drops what nobody has read in [keepFor], then whatever is still over
  /// [maxBytes], oldest first. Answers how many entries it removed.
  ///
  /// Nothing evicted this store, ever — no sweep, no cap, no age. It is shared
  /// by every worktree on the machine and it holds **raw** rgba, which is the
  /// right format for a diff that reads every pixel and the wrong one to keep
  /// forever: a frame is one to three megabytes, and one measured machine had
  /// reached 340MB of them.
  ///
  /// **Age first, size second, and both are needed.** Age is what actually
  /// accumulates here: a commit gets compared for a week and then nobody ever
  /// asks about it again, and no size cap large enough to be useful will ever
  /// notice. The cap is the backstop for the other shape — one enormous
  /// catalog compared repeatedly inside the window — and it is deliberately
  /// generous, because evicting an entry that is about to be asked for costs a
  /// whole render pass where keeping it costs a megabyte.
  ///
  /// **An entry is its group.** The bytes, the `.json` beside them and the
  /// `.tree.json` beside that are one render and are dropped together;
  /// [has] answers off the bytes, so a half-swept entry would be re-rendered
  /// with its stale record still on disk. A `.part` left by a killed write is
  /// litter and goes on age alone.
  ///
  /// Every failure is swallowed per entry, as housekeeping should be.
  int sweep({
    Duration keepFor = const Duration(days: 14),
    int maxBytes = 2 * 1024 * 1024 * 1024,
  }) {
    var groups = <String, _Entry>{};
    var cutoff = DateTime.now().subtract(keepFor);
    List<FileSystemEntity> found;
    try {
      found = Directory(root).listSync(recursive: true);
    } on FileSystemException {
      return 0;
    }

    for (var entity in found) {
      if (entity is! File) continue;
      FileStat stat;
      try {
        stat = entity.statSync();
      } on FileSystemException {
        continue;
      }
      var group = groups.putIfAbsent(_groupOf(entity.path), _Entry.new);
      group.files.add(entity);
      group.bytes += stat.size;
      if (stat.modified.isAfter(group.touched)) group.touched = stat.modified;
    }

    var total = 0;
    var live = <_Entry>[];
    var deleted = 0;
    for (var group in groups.values) {
      if (group.touched.isBefore(cutoff)) {
        if (group.delete()) deleted++;
        continue;
      }
      total += group.bytes;
      live.add(group);
    }

    if (total <= maxBytes) return deleted;
    live.sort((a, b) => a.touched.compareTo(b.touched));
    for (var group in live) {
      if (total <= maxBytes) break;
      if (group.delete()) {
        total -= group.bytes;
        deleted++;
      }
    }
    return deleted;
  }

  /// The path an entry's files share: the bytes' own path, which its two
  /// sidecars extend.
  static String _groupOf(String path) {
    for (var suffix in const ['.tree.json', '.replay.json', '.json', '.part']) {
      if (path.endsWith(suffix)) {
        return path.substring(0, path.length - suffix.length);
      }
    }
    return path;
  }
}

/// One render's files, as [ShotCache.sweep] accounts for them.
class _Entry {
  final files = <File>[];
  var bytes = 0;
  var touched = DateTime.fromMillisecondsSinceEpoch(0);

  bool delete() {
    var any = false;
    for (var file in files) {
      try {
        file.deleteSync();
        any = true;
      } on FileSystemException {
        // Swept by another comparison already, which is the expected race.
      }
    }
    return any;
  }
}

/// What a cached picture is, beyond its bytes.
class ShotRecord {
  const ShotRecord({
    required this.format,
    required this.width,
    required this.height,
    this.entryId,
    this.complaint,
    this.treeFormat,
  });

  factory ShotRecord.fromJson(Map<String, Object?> json) => ShotRecord(
    format: json['format'] as String? ?? 'png',
    width: json['width'] as int? ?? 0,
    height: json['height'] as int? ?? 0,
    entryId: json['entry'] as String?,
    complaint: json['complaint'] as String?,
    treeFormat: json['treeFormat'] as int?,
  );

  /// `raw` — rgba8888 rows, [width]×[height]×4 — or `png`.
  ///
  /// Raw is what a comparison stores: the diff reads pixels rather than files,
  /// so a PNG would be encoded on the way in and decoded straight back out,
  /// and only the handful of pictures that end up on screen are ever encoded.
  /// What that costs is the disk, which is [ShotCache.sweep]'s problem.
  final String format;

  final int width;
  final int height;

  /// Which entry this was, for a human reading the cache directory. Not part
  /// of the key and not read by anything: the key is the identity.
  final String? entryId;

  /// What the framework said while this frame was drawn, when it drew it
  /// anyway — an overflow, a missing font.
  ///
  /// Kept beside the picture rather than recomputed, because the picture
  /// outlives the render: a cached frame is served without the guest that
  /// produced it, and "this overflows now" would otherwise be a finding that
  /// survives exactly one comparison.
  final String? complaint;

  /// The format the tree beside this picture was read in — see
  /// `InspectTree.format`. Kept for the reason [complaint] is: a cached frame
  /// is served without the guest that read it, and two sides whose trees were
  /// read by different walks have to be told apart without one.
  final int? treeFormat;

  Map<String, Object?> toJson() => {
    'format': format,
    'width': width,
    'height': height,
    'entry': ?entryId,
    'complaint': ?complaint,
    'treeFormat': ?treeFormat,
  };
}
