/// Where the changes screen reads a checkout's delta from, when not from the
/// checkout itself.
///
/// The screen's default is the checkout: git on an isolate, the working tree
/// for the bodies a diff cannot draw, a log file under the home directory for
/// the notes. Every one of those is a door the screen already had for its
/// tests, and this is the three of them as one thing the shell can be handed
/// — which is what the studio's recordings do, and the only thing they do.
library;

import 'change_set.dart';
import 'file_contents.dart';
import 'review_store.dart';

class ChangesSources {
  const ChangesSources({
    required this.load,
    required this.contents,
    required this.reviewStore,
    this.comparisonUnavailable,
  });

  /// One worktree's delta. Replaces the probe on an isolate.
  final Future<ChangeSet> Function(String worktreePath) load;

  /// The bytes behind the bodies: images, rendered markdown, an untracked
  /// file's lines.
  final FileContentStore Function(String worktreePath) contents;

  /// Where the notes taken on the screen go.
  final ReviewStore Function(String worktreePath) reviewStore;

  /// Why the strip above the screen offers no comparison, or null when a
  /// comparison is possible. A comparison builds and runs the base checkout,
  /// which nothing but a real one can.
  final String? comparisonUnavailable;
}
