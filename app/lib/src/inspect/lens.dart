import 'dart:io';

import 'package:path/path.dart' as p;

import '../run/handle.dart';

/// How much of an observation to hand back, as one word.
///
/// Four presets rather than six booleans, because the booleans are the
/// thing a caller will not read: `screen`, `screenshot`, `styles`, `tree`,
/// `find`, `at` is six decisions per call, and measuring the real combinations
/// turned up about four. A lens is the answer to "I am doing this kind of
/// work" rather than to "I want these fields".
///
/// It lives here rather than in the run plugin because the vocabulary is meant
/// to mean the same thing on a preview and on a scenario step — the same four
/// words, the same contents, one place to change them. Only `run` reads it
/// today; that is adoption pending, not a different design.
///
/// Explicit flags always win. `{lens: 'look', screenshot: false}` returns
/// no picture. A preset is a default, and a default that overrode what the
/// caller actually said would be a trap.
enum ObserveLens {
  /// Driving: the screen, what it printed, what broke. No picture, no tree.
  ///
  /// The default, and the one nearly every step wants — measured at ~180
  /// tokens on a simple screen and ~1080 on a dense one, against ~1440 for a
  /// picture alone and ~19,500 for a tree.
  act(picture: false, styles: false, tree: false),

  /// Looking: the screen and a picture of it. For "does this look right",
  /// which is the one question pixels answer and nothing else does.
  look(picture: true, styles: false, tree: false),

  /// Working on the design: the screen, a picture, and every distinct text
  /// style on it. `styles` is ~185 tokens and settles most of the arguments —
  /// two greys that should be one, a ramp with both 11.5 and 12.5 in it.
  design(picture: true, styles: true, tree: false),

  /// Everything, tree included. **~20,000 tokens**, said plainly because a
  /// friendly name on an expensive thing is how budgets disappear. Reach for
  /// it when the question is genuinely about structure and `find`, `at` and a
  /// scoped `tree` have not answered it.
  raw(picture: true, styles: true, tree: true);

  const ObserveLens({
    required this.picture,
    required this.styles,
    required this.tree,
  });

  final bool picture;
  final bool styles;
  final bool tree;

  static ObserveLens? byName(String? name) {
    if (name == null || name.isEmpty) return null;
    for (var lens in values) {
      if (lens.name == name) return lens;
    }
    return null;
  }

  /// The refusal, written to be actable: it lists what there is.
  static String unknown(String name) =>
      'no lens "$name". Use one of ${values.map((l) => l.name).join(', ')}. '
      'act is the screen alone, look adds the picture, design adds the text '
      'styles, raw adds the whole tree and costs about 20,000 tokens.';
}

/// Where a run's pinned lens is kept: `app-<key>.lens`, beside the handle.
///
/// On disk rather than in a field, and for the same reason the journal is:
/// every surface here opens a fresh session per call, so a preference held in
/// memory would last exactly one call — and one held in the MCP server would
/// be invisible to `fw` and to the GUI, which is not how anything else in this
/// project works.
String? lensPathFor(RunHandle handle) {
  var handlePath = handle.handlePath;
  if (handlePath == null) return null;
  return '${p.withoutExtension(handlePath)}.lens';
}

/// The lens pinned for this run, or null when none is pinned.
ObserveLens? pinnedLens(RunHandle handle) {
  var path = lensPathFor(handle);
  if (path == null) return null;
  var file = File(path);
  if (!file.existsSync()) return null;
  try {
    return ObserveLens.byName(file.readAsStringSync().trim());
  } on FileSystemException {
    return null;
  }
}

/// Pins [lens] for this run, or clears the pin when it is null.
void pinLens(RunHandle handle, ObserveLens? lens) {
  var path = lensPathFor(handle);
  if (path == null) return;
  var file = File(path);
  try {
    if (lens == null) {
      if (file.existsSync()) file.deleteSync();
    } else {
      file.writeAsStringSync(lens.name);
    }
  } on FileSystemException {
    // A preference is not worth failing a step over.
  }
}
