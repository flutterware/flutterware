/// Spike: what deciding a comparison plan pays to hash source closures.
///
/// A catalog's entries overlap almost entirely — the shell, the design system
/// and the package's own library sit in every one of them — so hashing each
/// entry's closure independently reads the same file once per entry. This
/// measures that against reading each unique file once, on a real catalog.
///
///     cd app && fvm dart run tool/spike/closure_cost.dart [app|fixtures/probe_app]
///
/// This file is a measuring instrument; nothing ships from it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterware_app/src/comparison/closure.dart';
import 'package:flutterware_app/src/comparison/import_graph.dart';
import 'package:flutterware_app/src/comparison/skip.dart';
import 'package:flutterware_app/src/previews/discovery.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) {
  var packagePath = args.isEmpty ? 'app' : args.first;
  var worktree = _repoRoot();
  var packageRoot = p.normalize(p.join(worktree, packagePath));
  if (!Directory(packageRoot).existsSync()) {
    print('no package at $packageRoot');
    exit(64);
  }

  var scan = CatalogScanner(projectRoot: packageRoot).scan();
  var graph = ImportGraph.read(
    root: worktree,
    packageConfig: p.join(worktree, '.dart_tool', 'package_config.json'),
  );
  var closures = <String, List<String>>{};
  for (var entry in scan.entries) {
    closures[entry.id] = graph.closureOf(
      p.normalize(p.join(packagePath, entry.path)),
    );
  }
  print('$packagePath: ${closures.length} previews');
  if (closures.isEmpty) {
    print('nothing to measure: no entry under $packageRoot carries a @Preview');
    exit(64);
  }

  var sizes = [for (var c in closures.values) c.length]..sort();
  var unique = <String>{for (var c in closures.values) ...c};
  var summed = closures.values.fold(0, (sum, c) => sum + c.length);
  var uniqueBytes = unique.fold(
    0,
    (sum, f) => sum + _sizeOf(p.join(worktree, f)),
  );
  var summedBytes = closures.values.fold(
    0,
    (sum, c) => sum + c.fold(0, (s, f) => s + _sizeOf(p.join(worktree, f))),
  );
  print(
    'closure size: p50=${_at(sizes, .5)} p90=${_at(sizes, .9)} '
    'max=${sizes.last} files',
  );
  print(
    'unique files ${unique.length} (${_mb(uniqueBytes)}); '
    'summed over entries $summed reads (${_mb(summedBytes)})',
  );

  var pixels = PixelInputs.of(packagePath: packagePath, roots: [worktree]);

  var cold = <String, String>{};
  var coldTime = _time(() {
    for (var id in closures.keys) {
      cold[id] = SourceClosure.of(
        closures[id]!,
        root: worktree,
      ).merge(pixels.inRoot(worktree)).fingerprint;
    }
  });
  print('keys, every entry re-reads its closure: ${coldTime}ms');

  var warm = <String, String>{};
  var digests = DigestCache();
  var warmTime = _time(() {
    for (var id in closures.keys) {
      warm[id] = SourceClosure.of(
        closures[id]!,
        root: worktree,
        digests: digests,
      ).merge(pixels.inRoot(worktree)).fingerprint;
    }
  });
  print(
    'keys, each unique file read once:       ${warmTime}ms'
    '   -> ${(coldTime / warmTime).toStringAsFixed(1)}x'
    ' (${digests.files} files read)',
  );

  // The whole point of memoising the lookup rather than recomposing the hash:
  // the keys have to be the bytes they always were, or every cached picture
  // on every machine is orphaned.
  var moved = [
    for (var id in closures.keys)
      if (cold[id] != warm[id]) id,
  ];
  print(
    moved.isEmpty
        ? 'keys identical: ${cold.length} entries'
        : 'KEYS MOVED: ${moved.length} of ${cold.length} — ${moved.first}',
  );

  // The composition, recomposed from outside the class. It reads as a space
  // and is a NUL — see [SourceClosure.separator].
  var someId = closures.keys.first;
  var plain = SourceClosure.of(closures[someId]!, root: worktree);
  var pk = plain.digests.keys.toList()..sort();
  var pb = StringBuffer();
  for (var key in pk) {
    pb
      ..write(key)
      ..write(SourceClosure.separator)
      ..write(plain.digests[key])
      ..write(SourceClosure.separator);
  }
  print(
    'recomposed $someId: '
    '${_sha1(pb.toString()) == plain.fingerprint ? 'matches' : 'differs from'}'
    ' ${plain.fingerprint}',
  );
}

String _sha1(String s) => sha1.convert(utf8.encode(s)).toString();

int _sizeOf(String path) {
  try {
    return File(path).lengthSync();
  } on FileSystemException {
    return 0;
  }
}

int _at(List<int> sorted, double q) =>
    sorted[(sorted.length * q).clamp(0, sorted.length - 1).floor()];

String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';

int _time(void Function() body) {
  var watch = Stopwatch()..start();
  body();
  return watch.elapsedMilliseconds;
}

String _repoRoot() {
  var dir = p.canonicalize(Directory.current.path);
  while (true) {
    if (Directory(p.join(dir, '.git')).existsSync() ||
        File(p.join(dir, '.git')).existsSync()) {
      return dir;
    }
    var parent = p.dirname(dir);
    if (parent == dir) throw StateError('no repo root above $dir');
    dir = parent;
  }
}
