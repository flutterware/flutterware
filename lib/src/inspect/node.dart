/// The widget tree of one entry, as it is carried between processes.
///
/// Plain Dart on purpose, exactly like `ui_catalog/knob.dart`: `fw` and the MCP
/// server link this and neither can reach `dart:ui`. The half that walks a live
/// tree lives in `guest_inspect.dart` and is the only Flutter in here.
library;

import 'package:path/path.dart' as p;

import '../utils/identity_hash.dart';

/// Where a widget's constructor was called.
///
/// Only ever present when the program was compiled with
/// `--track-widget-creation` — see `DaemonConfig.trackWidgetCreation`, which is
/// why it is on. The location is read out of the framework's inspector rather
/// than off the widget: the kernel transform stores it behind a private
/// interface in `package:flutter`, and Dart mangles private names per library,
/// so no code outside that library can name the field. Not even dynamically.
class InspectSource {
  const InspectSource({
    required this.file,
    required this.line,
    required this.column,
  });

  factory InspectSource.fromJson(Map<String, Object?> json) => InspectSource(
    file: json['file'] as String? ?? '',
    line: json['line'] as int? ?? 0,
    column: json['column'] as int? ?? 0,
  );

  /// A `file://` URI, as the framework reports it.
  final String file;
  final int line;
  final int column;

  /// `path/to/file.dart:12:5`, with [relativeTo] stripped when it matches.
  ///
  /// An absolute URI is the truth and a relative path is what anyone reading
  /// the output wants, so this keeps the first and prints the second.
  ///
  /// A tree read over the VM service reaches *above* the user's code into the
  /// framework, and those files are genuinely outside the worktree — so
  /// [relativeTo] has nothing to strip and the reader got the whole of
  /// `/Users/…/.flutterware/sdks/3.47.0-0.1.pre/packages/flutter/lib/src/widgets/binding.dart`,
  /// six wrapped lines of it in a detail pane. [_packageUri] folds those back
  /// to `package:flutter/src/widgets/binding.dart`: shorter, and the name a
  /// reader would have used anyway.
  ///
  /// The worktree wins when both could apply. A path inside the checkout is
  /// one the reader can open, and `app/lib/src/shell/shell_view.dart` says
  /// where it *is* where a package URI only says what it belongs to.
  ///
  /// The relative path is a name, so it reads with `/` on every host — the
  /// same file says the same thing from a Mac, a Windows box and the web
  /// export. An absolute one stays as the platform spells it: that one is for
  /// opening.
  String describe({String? relativeTo}) {
    var path = Uri.tryParse(file)?.toFilePath() ?? file;
    // Non-empty, because the web export passes `''` — every path starts with
    // the empty string, so the old test matched, stripped nothing, and then
    // ate the leading slash on its way out.
    if (relativeTo != null &&
        relativeTo.isNotEmpty &&
        p.isWithin(relativeTo, path)) {
      var name = p.url.joinAll(p.split(p.relative(path, from: relativeTo)));
      return '$name:$line:$column';
    }
    return '${_packageUri(path) ?? path}:$line:$column';
  }

  /// `package:foo/bar.dart` for a path in a place packages are *kept*, or null.
  ///
  /// It recognises a layout; it does not resolve a package config. The
  /// three it knows are the Flutter SDK (`…/packages/flutter/lib/…`), the pub
  /// cache (`…/hosted/pub.dev/provider-6.1.2/lib/…`) and the git cache
  /// (`…/git/foo-<sha>/lib/…`) — each one a marker segment away from certainty,
  /// which is why a marker is required rather than "the directory above `lib`
  /// is the package". A path dependency checked out beside the worktree looks
  /// exactly like an ordinary directory, and guessing a package name off it
  /// would put a confident wrong label on a real file. Those stay absolute.
  static String? _packageUri(String path) {
    var parts = p.split(path);
    for (var i = 0; i < parts.length; i++) {
      var at = switch (parts[i]) {
        'packages' || 'git' => i + 1,
        // `hosted` is followed by the server the package came from.
        'hosted' => i + 2,
        _ => -1,
      };
      // The directory, then `lib`, then at least one segment of file.
      if (at < 0 || at + 2 >= parts.length || parts[at + 1] != 'lib') continue;
      if (_packageNamed(parts[at]) case var name?) {
        return 'package:$name/${parts.sublist(at + 2).join('/')}';
      }
    }
    return null;
  }

  /// A package name straight, or `foo-1.2.3+4` / `foo-<40 hex>` as the caches
  /// spell one, or null when the directory is not named after a package at all.
  static String? _packageNamed(String dir) =>
      _bare.firstMatch(dir)?.group(1) ?? _stamped.firstMatch(dir)?.group(1);

  static final _bare = RegExp(r'^([a-z_][a-z0-9_]*)$');
  static final _stamped = RegExp(r'^([a-z_][a-z0-9_]*)-(?:\d.*|[0-9a-f]{40})$');

  Map<String, Object?> toJson() => {
    'file': file,
    'line': line,
    'column': column,
  };
}

/// A translation key, and which characters of this node's text it produced.
///
/// Resolved by **object identity**, not by comparing words: the catalog's
/// funnel hands out a distinct string per key, and the walk asks which key a
/// span's exact object came from. So two keys reading `Cancel` stay apart, and
/// a `'Cancel'` written inline in the UI is correctly not attributed to either.
///
/// One node can carry several — a `Text.rich` assembled from two keys, or from
/// a key and a name — which is why this records a range rather than claiming
/// the whole node.
class InspectKey {
  const InspectKey({
    required this.catalog,
    required this.key,
    this.start,
    this.end,
  });

  factory InspectKey.fromJson(Map<String, Object?> json) => InspectKey(
    catalog: json['catalog'] as String? ?? '',
    key: json['key'] as String? ?? '',
    start: json['start'] as int?,
    end: json['end'] as int?,
  );

  /// Which catalog, as `indexTranslations` was told. Recorded per key rather
  /// than per project: several catalogs in one UI is ordinary.
  final String catalog;

  final String key;

  /// Half-open range over the paragraph's plain text — what to highlight when
  /// showing a translator where their string is.
  ///
  /// Absent when the key was read off a widget property rather than a span.
  /// A markdown source carries `**` that never reaches a glyph, so an offset
  /// into it would point at the wrong character; the whole node is the
  /// occurrence instead, which is the right crop for a paragraph anyway.
  final int? start;
  final int? end;

  Map<String, Object?> toJson() => {
    'catalog': catalog,
    'key': key,
    if (start != null) 'start': start,
    if (end != null) 'end': end,
  };

  @override
  String toString() => '$catalog/$key';
}

/// One key, on one screen, in one place — what an export is a list of.
class TranslationOccurrence {
  const TranslationOccurrence({
    required this.key,
    required this.node,
    this.layout,
    this.offstage = false,
    this.overflowed = false,
  });

  final InspectKey key;

  /// The node that drew it, so a reader can go back to the tree for context.
  final String node;

  /// Where on the screen, for the crop. Null for a node with no box of its own,
  /// which a paragraph always has — kept nullable because the type it comes
  /// from is.
  final InspectLayout? layout;

  /// Present in the tree but not on the screen. Kept rather than filtered: a
  /// key that only ever appears offstage is a finding, and a ranking that had
  /// silently dropped it could not say so.
  final bool offstage;

  /// The words did not fit. A ranking prefers an occurrence where they did,
  /// and a report of these is the localisation bug list.
  final bool overflowed;

  Map<String, Object?> toJson() => {
    ...key.toJson(),
    'node': node,
    if (layout case var layout?)
      'rect':
          '${layout.x.round()},${layout.y.round()} '
          '${layout.width.round()}×${layout.height.round()}',
    if (offstage) 'offstage': true,
    if (overflowed) 'overflowed': true,
  };
}

/// Words on a screen that belong to no catalog.
class UnkeyedText {
  const UnkeyedText({
    required this.text,
    required this.node,
    this.layout,
    this.source,
    this.offstage = false,
  });

  final String text;
  final String node;
  final InspectLayout? layout;

  /// Where the widget was built, which is what turns "this is not translated"
  /// into somewhere to go.
  final InspectSource? source;
  final bool offstage;

  Map<String, Object?> toJson() => {
    'text': text,
    'node': node,
    if (layout case var layout?)
      'rect':
          '${layout.x.round()},${layout.y.round()} '
          '${layout.width.round()}×${layout.height.round()}',
    if (source case var source?) 'source': source.toJson(),
    if (offstage) 'offstage': true,
  };
}

/// Where a widget ended up and what it was allowed.
///
/// This is the half the inspector cannot answer. Its tree carries no geometry
/// at all, and `getLayoutExplorerNode` is one call per node — so a caller
/// asking "why is this zero-height" would pay a round trip per candidate.
/// Reading it off the [RenderObject] while the tree is being walked costs
/// nothing extra and puts the answer in the same node as the question.
class InspectLayout {
  const InspectLayout({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.constraints,
    this.isRepaintBoundary = false,
    this.flex,
    this.flexFactor,
    this.flexFit,
  });

  factory InspectLayout.fromJson(Map<String, Object?> json) => InspectLayout(
    x: _double(json['x']),
    y: _double(json['y']),
    width: _double(json['width']),
    height: _double(json['height']),
    constraints: switch (json['constraints']) {
      Map c => InspectConstraints.fromJson(c.cast<String, Object?>()),
      _ => null,
    },
    isRepaintBoundary: json['repaintBoundary'] as bool? ?? false,
    flex: switch (json['flex']) {
      Map f => InspectFlex.fromJson(f.cast<String, Object?>()),
      _ => null,
    },
    flexFactor: json['flexFactor'] as int?,
    flexFit: json['flexFit'] as String?,
  );

  /// Position in the guest's own coordinates — the same space a capture is
  /// taken in, so a rect here crops that PNG without a transform.
  final double x;
  final double y;
  final double width;
  final double height;

  /// What the parent allowed. Half of every layout question is here rather
  /// than in [width] and [height]: a box that is 0 wide because it was given
  /// `maxWidth: 0` is a different bug from one that chose to be.
  final InspectConstraints? constraints;

  final bool isRepaintBoundary;

  /// Set when this node *is* a `Row`, `Column` or `Flex`.
  final InspectFlex? flex;

  /// Set when this node is a *child* of one — the `Expanded`/`Flexible` story,
  /// read off the parent data rather than off any widget.
  final int? flexFactor;

  /// `tight` or `loose`.
  final String? flexFit;

  Map<String, Object?> toJson() => {
    // Guarded for the same reason as the constraints, though a laid-out box
    // should never be non-finite: an encoder that throws takes down the whole
    // read, so nothing that reaches it is left to chance.
    'x': _finite(x),
    'y': _finite(y),
    'width': _finite(width),
    'height': _finite(height),
    if (constraints != null) 'constraints': constraints!.toJson(),
    if (isRepaintBoundary) 'repaintBoundary': true,
    if (flex != null) 'flex': flex!.toJson(),
    if (flexFactor != null) 'flexFactor': flexFactor,
    if (flexFit != null) 'flexFit': flexFit,
  };

  /// Whether [other] is the same box, laid out the same way.
  ///
  /// Every field, including the flex ones: a `Row` and the `Padding` that
  /// happens to fit it exactly are not interchangeable, and neither are a
  /// child given `flex: 2` and its wrapper.
  bool sameAs(InspectLayout other) =>
      x == other.x &&
      y == other.y &&
      width == other.width &&
      height == other.height &&
      isRepaintBoundary == other.isRepaintBoundary &&
      flexFactor == other.flexFactor &&
      flexFit == other.flexFit &&
      (constraints?.sameAs(other.constraints) ?? other.constraints == null) &&
      (flex?.sameAs(other.flex) ?? other.flex == null);

  static double _double(Object? value) => switch (value) {
    num n => n.toDouble(),
    _ => 0,
  };

  static double _finite(double value) => value.isFinite ? value : 0;
}

/// What a parent allowed a child to be.
class InspectConstraints {
  const InspectConstraints({
    required this.minWidth,
    required this.maxWidth,
    required this.minHeight,
    required this.maxHeight,
  });

  factory InspectConstraints.fromJson(Map<String, Object?> json) =>
      InspectConstraints(
        minWidth: _in(json['minWidth']),
        maxWidth: _in(json['maxWidth']),
        minHeight: _in(json['minHeight']),
        maxHeight: _in(json['maxHeight']),
      );

  final double minWidth;
  final double maxWidth;
  final double minHeight;
  final double maxHeight;

  /// Unbounded is absent, not `Infinity`. JSON has no infinity and
  /// `jsonEncode` throws on one, which is not a theoretical corner: an
  /// unbounded `maxWidth` is what most of a real tree is laid out under, so
  /// the first entry with a `Column` in it failed to encode at all.
  ///
  /// It was written as an explicit `null` first, which [_in] has always read
  /// the same way as a missing key. Leaving the key out says the identical
  /// thing in sixteen fewer characters, and `"maxWidth": null` on two axes of
  /// every node of a real tree was 8 KB of a 234 KB read.
  Map<String, Object?> toJson() => {
    'minWidth': ?_out(minWidth),
    'maxWidth': ?_out(maxWidth),
    'minHeight': ?_out(minHeight),
    'maxHeight': ?_out(maxHeight),
  };

  static double? _out(double value) => value.isFinite ? value : null;

  static double _in(Object? value) => switch (value) {
    num n => n.toDouble(),
    // Absent means unbounded, per [toJson].
    _ => double.infinity,
  };

  bool sameAs(InspectConstraints? other) =>
      other != null &&
      minWidth == other.minWidth &&
      maxWidth == other.maxWidth &&
      minHeight == other.minHeight &&
      maxHeight == other.maxHeight;

  /// `w 0..900, h 0..∞` — how a human reads it, and infinity written as
  /// something a terminal can print.
  String describe() =>
      'w ${_n(minWidth)}..${_n(maxWidth)}, h ${_n(minHeight)}..${_n(maxHeight)}';

  /// Whole pixels without the `.0`, which is what every other number in the
  /// detail pane does. This one printed `w 573.0..573.0` two lines under
  /// `size 573 × 101` — the same measurement of the same widget in two
  /// notations, which reads as two different kinds of number.
  static String _n(double value) => switch (value) {
    _ when value.isInfinite => '∞',
    _ when value == value.roundToDouble() => '${value.round()}',
    _ => value.toStringAsFixed(1),
  };
}

/// A `Row`, `Column` or `Flex`, as its children experience it.
class InspectFlex {
  const InspectFlex({
    required this.direction,
    this.mainAxisAlignment,
    this.crossAxisAlignment,
    this.mainAxisSize,
  });

  factory InspectFlex.fromJson(Map<String, Object?> json) => InspectFlex(
    direction: json['direction'] as String? ?? '',
    mainAxisAlignment: json['mainAxisAlignment'] as String?,
    crossAxisAlignment: json['crossAxisAlignment'] as String?,
    mainAxisSize: json['mainAxisSize'] as String?,
  );

  final String direction;
  final String? mainAxisAlignment;
  final String? crossAxisAlignment;
  final String? mainAxisSize;

  bool sameAs(InspectFlex? other) =>
      other != null &&
      direction == other.direction &&
      mainAxisAlignment == other.mainAxisAlignment &&
      crossAxisAlignment == other.crossAxisAlignment &&
      mainAxisSize == other.mainAxisSize;

  Map<String, Object?> toJson() => {
    'direction': direction,
    if (mainAxisAlignment != null) 'mainAxisAlignment': mainAxisAlignment,
    if (crossAxisAlignment != null) 'crossAxisAlignment': crossAxisAlignment,
    if (mainAxisSize != null) 'mainAxisSize': mainAxisSize,
  };
}

/// One widget in the tree.
class InspectNode {
  const InspectNode({
    required this.id,
    required this.type,
    this.description,
    this.widgetKey,
    this.source,
    this.createdByLocalProject = false,
    this.offstage = false,
    this.properties = const {},
    this.textStyle = const {},
    this.inheritedStyle = const {},
    this.styleReplacesInherited,
    this.keys = const [],
    this.unkeyedText = const [],
    this.textOverflowed = false,
    this.layout,
    this.label,
    this.selected,
    this.children = const [],
    this.elidedChildren = 0,
  });

  /// `Form-[LabeledGlobalKey<FormState>#acc1d]` → `('Form', '[LabeledGlobalKey<FormState>#]')`.
  ///
  /// The framework's `Widget.toStringShort()` is `'$type-$key'`, so a keyed
  /// widget reaches either converter with two facts fused into one string.
  /// This takes them apart, and is the *only* place that does — the guest and
  /// the VM-service path both call it, on the same string, so a tree read
  /// through one is spelled exactly like a tree read through the other.
  ///
  /// **The identity hash goes.** A key with no value of its own stringifies
  /// through `describeIdentity`/`shortHash`, which is `hashCode` — assigned per
  /// allocation, so the same `GlobalKey<FormState>()` spells itself `#acc1d`
  /// in one process and `#0507e` in the next. [InspectNode] exists to be
  /// carried between processes; a value that means nothing outside the one
  /// that minted it has no business travelling in it. Left in, it cost a
  /// previews comparison 21 entries reported as changed with zero pixels
  /// changed, each one a `Form` failing to match itself — and worse than the
  /// noise, an unmatched node's subtree is never walked, so every one of those
  /// false positives was hiding whatever really did change beneath it.
  ///
  /// Returns the description with the key removed, which for the common case
  /// is the bare type and so goes on to be dropped as saying nothing.
  static ({String? description, String? key}) splitKey(
    String? description,
    String type,
  ) {
    const none = (description: null, key: null);
    if (description == null) return none;
    var open = type.length + 1;
    // `type` + `-` + at least `[]`.
    if (description.length < open + 2 ||
        !description.startsWith(type) ||
        description[type.length] != '-' ||
        description[open] != '[') {
      return (description: description, key: null);
    }
    // Balanced rather than "up to the last `]`": a `ValueKey` of a list spells
    // itself `[<[1, 2]>]`, and a description can carry properties after the
    // key that have brackets of their own.
    var depth = 0;
    for (var i = open; i < description.length; i++) {
      switch (description[i]) {
        case '[':
          depth++;
        case ']':
          depth--;
          if (depth == 0) {
            return (
              description: type + description.substring(i + 1),
              key: withoutIdentityHash(description.substring(open, i + 1)),
            );
          }
      }
    }
    return (description: description, key: null);
  }

  /// The ambient style as [toJson] wrote it: a map, or `"same"` standing in
  /// for one byte-identical to [textStyle].
  ///
  /// Absent and `"same"` are different answers, which is the whole reason
  /// the sentinel is a value rather than an omission: nothing captured means
  /// no reader looked, and the detail pane offers no merge card for it. A
  /// widget that set no style of its own captured plenty — it simply captured
  /// the same thing twice.
  static Map<String, String> _readInherited(
    Object? json,
    Map<String, String> textStyle,
  ) => switch (json) {
    'same' => textStyle,
    Map style => style.cast<String, String>(),
    _ => const {},
  };

  factory InspectNode.fromJson(Map<String, Object?> json) {
    var textStyle = switch (json['style']) {
      Map style => style.cast<String, String>(),
      _ => const <String, String>{},
    };
    return InspectNode(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? '',
      description: json['description'] as String?,
      widgetKey: json['widgetKey'] as String?,
      createdByLocalProject: json['local'] as bool? ?? false,
      offstage: json['offstage'] as bool? ?? false,
      elidedChildren: json['elided'] as int? ?? 0,
      label: json['label'] as String?,
      selected: json['selected'] as bool?,
      properties: switch (json['properties']) {
        Map properties => properties.cast<String, String>(),
        _ => const {},
      },
      textStyle: textStyle,
      inheritedStyle: _readInherited(json['inherited'], textStyle),
      styleReplacesInherited: json['styleReplaces'] as bool?,
      keys: [
        for (var key in json['keys'] as List? ?? const [])
          InspectKey.fromJson((key as Map).cast<String, Object?>()),
      ],
      unkeyedText: [
        for (var text in json['unkeyed'] as List? ?? const []) '$text',
      ],
      textOverflowed: json['overflowed'] as bool? ?? false,
      layout: switch (json['layout']) {
        Map layout => InspectLayout.fromJson(layout.cast<String, Object?>()),
        _ => null,
      },
      source: switch (json['source']) {
        Map<String, Object?> source => InspectSource.fromJson(source),
        Map source => InspectSource.fromJson(source.cast<String, Object?>()),
        _ => null,
      },
      children: [
        for (var child in json['children'] as List? ?? const [])
          InspectNode.fromJson((child as Map).cast<String, Object?>()),
      ],
    );
  }

  /// The node's identity, and the whole reason this type exists rather than
  /// the inspector's JSON being passed through.
  ///
  /// Derived from the tree's shape, never assigned. The framework's ids
  /// (`inspector-42`) are minted per object group, refcounted, and die with the
  /// process — which is fatal here, because every `fw` invocation and every MCP
  /// call opens a fresh session and holds nothing. An agent that reads a tree
  /// in one process and asks about a node in the next has to be talking about
  /// the same node, and only a derived id can promise that.
  ///
  /// The form is the child-index path from the subtree root: `''` for the root,
  /// then `0`, `0/1`, `0/1/2`. Stable as long as the tree is, which is the most
  /// any structural id can offer — see [InspectTree.nodeAt] for what a caller
  /// gets when it is not.
  final String id;

  /// The widget's runtime type — `Padding`, `_Dashboard`.
  final String type;

  /// The framework's own one-line description, which carries more than the
  /// type: `Text("Save")`, `SizedBox(width: 8.0)`. Null when it says nothing
  /// the type does not.
  ///
  /// The widget's key is **not** in here, though the framework spells the two
  /// as one string — see [splitKey], which takes them apart.
  final String? description;

  /// The widget's key as the framework spells one — `[<'save'>]`,
  /// `[GlobalKey#]` — or null for the great majority of widgets, which have
  /// none.
  ///
  /// Its own field rather than half of [description], because it answers a
  /// different question. A description says what a widget *is*; a key is the
  /// author saying *which one* it is, and so is the strongest evidence there
  /// can be that two nodes read in two places are the same node. Fused into
  /// the description it was the exact opposite of that — see [splitKey].
  ///
  /// Identity hashes are elided, so this is comparable across processes and
  /// across rebuilds. `[GlobalKey#]` says *keyed by a GlobalKey* and no more,
  /// which is all a bare `GlobalKey()` ever said about itself.
  final String? widgetKey;

  final InspectSource? source;

  /// Whether this widget is in the tree but not on the screen.
  ///
  /// True for content nobody can see or touch: a route kept alive under the
  /// one that covers it, an `Offstage`/`Visibility(visible: false)` subtree,
  /// the hidden children of an `IndexedStack`. Such nodes keep their
  /// last-laid-out [layout] — **stale rects that overlap the visible screen**
  /// — which is why [InspectTree.nodeAtPoint] skips them and the tree view
  /// folds them away by default. See `guest_inspect.dart` for how it is
  /// detected; the VM-service path (`run`) cannot detect it and leaves this
  /// false.
  final bool offstage;

  /// Whether the framework considers this the user's code rather than
  /// `package:flutter`'s.
  ///
  /// This is what "summary tree" means, and it is decided by [source] — so
  /// without creation tracking it is false for everything and a summary tree
  /// is byte-for-byte the full one. Measured: `dashboard` is 695 nodes either
  /// way with tracking off, and 51 with it on.
  final bool createdByLocalProject;

  /// What the widget says about itself — its own diagnostics, filtered.
  ///
  /// `Padding` reports `padding: EdgeInsets.all(8.0)`; `Text` reports its
  /// alignment and overflow. In declaration order, values as the framework
  /// describes them, filtered to `DiagnosticLevel.info` and capped in the
  /// walk (see `guest_inspect.dart`) — the JSON is read by agents as well as
  /// the detail pane, and a `TextStyle` dump nobody asked for is most of a
  /// node's bytes. Empty for the VM-service path (`run`), which cannot read
  /// widgets — the same gap as [layout].
  final Map<String, String> properties;

  /// The style this node's glyphs were **actually painted with**, resolved.
  ///
  /// Empty for everything that draws no text, and for every reader that cannot
  /// get inside the app (`run`'s cockpit) — the same gap as [layout].
  ///
  /// It is a second bucket rather than more [properties] because the two
  /// answer different questions and one of them was being mistaken for the
  /// other. [properties] is what the *author* wrote: `Text.debugFillProperties`
  /// reports `style?.debugFillProperties(…)`, so a bare `Text` under a
  /// `MaterialApp` reports one property — its words — and says nothing about
  /// the 14pt Roboto it draws. This is the merged result: `DefaultTextStyle`,
  /// the theme slot behind it, `MediaQuery.boldTextOf` and the spacing
  /// overrides, all already applied. See `guest_inspect.dart` for where it is
  /// read from and what it cost.
  ///
  /// Keyed by the framework's own diagnostic names — `color`, `size`,
  /// `weight`, `family`, `letterSpacing`, `height`, `decoration` — so a row
  /// here and the same row in [properties] are the same measurement of the
  /// same field, which is what makes the two comparable. [debugLabel] rides
  /// along under its own name and is the provenance rather than a value.
  ///
  /// Separate from [properties] for a second, duller reason too: that map is
  /// capped at twelve entries, and a resolved style is ten of them.
  final Map<String, String> textStyle;

  /// The default text style in force where this widget sits — what the theme
  /// was offering here, **including for the fields the widget overrode.**
  ///
  /// The third column of the merge, and the only one not derivable from the
  /// other two. [textStyle] says what won and [properties] says what the
  /// widget asked for; neither can tell "you set 13" from "you set 13, and it
  /// was already 13". An override that changes nothing is a line of source
  /// that could go, and that is a thing a design system wants told.
  ///
  /// Ambient, which is not always the same as inherited — see
  /// [styleReplacesInherited]. Empty for everything that draws no text and for
  /// every reader outside the app.
  final Map<String, String> inheritedStyle;

  /// Whether the widget's own style **replaced** [inheritedStyle] rather than
  /// merging into it. Null when this kind of widget cannot say.
  ///
  /// `Text.build` merges the ambient style only when the widget's own is null
  /// or `inherit: true`, and Material's type-ramp entries are `inherit: false`
  /// — so `style: theme.textTheme.titleLarge` discards what was in scope
  /// rather than building on it. Without this a reader is shown a column of
  /// values that look like they contributed and did not.
  ///
  /// Tri-state for the same reason [selected] is: an `Icon` builds its
  /// paragraph internally and publishes no style to ask, and guessing there
  /// would be exactly the confident wrong answer this field exists to prevent.
  final bool? styleReplacesInherited;

  /// Whether [inheritedStyle] would serialise byte for byte as [textStyle].
  ///
  /// True for every text that sets no style of its own — most of them — where
  /// the resolved style *is* the ambient one. Measured on one scenario run:
  /// 2215 of 22714 tree bytes, 9%, spent writing the same seven pairs a
  /// second time.
  bool get _sameAsResolved =>
      inheritedStyle.length == textStyle.length &&
      inheritedStyle.entries.every((e) => textStyle[e.key] == e.value);

  /// Which translation keys produced this node's words, and where.
  ///
  /// Empty for a node that draws no text, for text that came from somewhere
  /// other than a catalog — a date, a name, a hardcoded literal — and for
  /// every node when no catalog was wired up. Absence is never a claim that
  /// the text *should* have had a key; see [unkeyedSpans] for the other half.
  final List<InspectKey> keys;

  /// This node's text spans that no catalog claimed — the words themselves.
  ///
  /// The counterpart to [keys], and what makes "untranslated text" answerable
  /// rather than merely countable. Most of it is text that has no
  /// key by construction — a formatted date, a person's name, a number — so
  /// this is a *list to classify*, never a list of defects.
  ///
  /// Spans rather than whole paragraphs, because a span is the unit a key
  /// attaches to: a `Text.rich` of a key plus a name contributes one of each.
  final List<String> unkeyedText;

  int get unkeyedSpans => unkeyedText.length;

  /// Whether this node's paragraph ran out of room — `maxLines` exceeded, so
  /// the words are ellipsised or clipped.
  ///
  /// Read off the paragraph while it is already in hand. This is the classic
  /// localisation bug: a label that fits in the language it was designed in and
  /// does not fit in the next one. The matrix already runs the
  /// language axis, so with this the question "which strings break in German"
  /// is a query rather than a feature.
  final bool textOverflowed;

  /// The style in one line — `14/400 #1D1B20 Roboto` — or null when this node
  /// draws no text.
  ///
  /// For the readers that pay per byte. A `find` hit spelling its style out in
  /// full is ten keys and ~70 tokens, and thirty of them is most of a reply;
  /// this is the four fields anybody scanning a list is scanning *for*, in
  /// about twelve. The whole map is still on the node for whoever opened one.
  String? get styleLine {
    if (textStyle.isEmpty) return null;
    var size = textStyle['size'];
    var weight = textStyle['weight'];
    var head = [?size, ?weight].join('/');
    return [
      if (head.isNotEmpty) head,
      ?textStyle['color'],
      ?textStyle['family'],
    ].join(' ');
  }

  /// Where it ended up, when it has a box.
  ///
  /// Null for a widget with no [RenderObject] of its own — a provider, a
  /// builder — which is most of a summary tree. That is why it is nullable
  /// rather than zero-filled: "it has no box" and "its box is empty" are
  /// different answers and only one of them is a bug.
  final InspectLayout? layout;

  /// What a screen reader would call this, from the semantics node this
  /// widget's render object contributes to.
  ///
  /// Reached through the render tree, never by comparing rectangles. A
  /// semantics node and a widget's box are not the same rectangle and the
  /// mismatch goes both ways: a `Checkbox`'s node is smaller than the
  /// `CheckboxListTile` that owns it, and a `Tab`'s is **9.5× larger** than the
  /// `Tab` widget, which is only its label. Matching by rect reported "Flutter
  /// does not publish tab selection", which is false — see
  /// `2026-08-13-screen-handback-spike-findings.md` § S6.
  ///
  /// It carries more than the words: Flutter writes its own positional hints in
  /// here, so a tab reads `"Tab A\nTab 1 of 2"`. Null off the VM-service path
  /// (`run`'s `inspect`), which cannot reach widgets, and null when the app has
  /// no semantics tree — a live app has none until something holds a
  /// `SemanticsHandle`.
  final String? label;

  /// Whether this is the current one of its group — **tri-state, and the third
  /// state is the point.**
  ///
  /// True when semantics says `isSelected`/`isChecked`/`isToggled`, false when
  /// it says only `hasSelectedState`/`hasCheckedState`/`hasToggledState`, and
  /// **null when nothing said** — which is different from false. Without the
  /// distinction "not selected" and "not selectable" are the same answer, and
  /// that difference is the whole value of the field.
  ///
  /// Eight of the ten Material selection idioms publish it (measured);
  /// `SegmentedButton` and hand-rolled `InkWell` tabs publish nothing, and for
  /// those this stays null rather than being guessed from a colour.
  final bool? selected;

  final List<InspectNode> children;

  /// How many children a depth cut removed, when one did.
  ///
  /// Zero everywhere in an unfiltered tree. It exists so a bounded read cannot
  /// be misread as a complete one: without it a node cut at the depth limit is
  /// indistinguishable from a leaf, and "this Row has no children" is a wrong
  /// answer rather than a short one. See [InspectFilter.maxDepth].
  final int elidedChildren;

  /// This node and everything under it, depth-first, with offstage subtrees
  /// folded to their flagged top node — reported, so a reader knows the
  /// content exists, and cut there, because a covered route is most of a
  /// tree's bulk and none of its picture.
  ///
  /// The fold does not apply when this node is itself offstage: whoever
  /// starts a walk *at* hidden content has asked about it.
  Iterable<InspectNode> get nodesFoldingOffstage =>
      _foldingOffstage(parentOffstage: offstage);

  Iterable<InspectNode> _foldingOffstage({required bool parentOffstage}) sync* {
    yield this;
    if (offstage && !parentOffstage) return;
    for (var child in children) {
      yield* child._foldingOffstage(parentOffstage: offstage);
    }
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    if (description != null) 'description': description,
    if (widgetKey != null) 'widgetKey': widgetKey,
    if (source != null) 'source': source!.toJson(),
    'local': createdByLocalProject,
    // Sparse: nearly every node is on stage, and the flag is only news when
    // it is true.
    if (offstage) 'offstage': true,
    if (properties.isNotEmpty) 'properties': properties,
    if (textStyle.isNotEmpty) 'style': textStyle,
    // `"same"` rather than the whole map again — see [_readInherited].
    if (inheritedStyle.isNotEmpty)
      'inherited': _sameAsResolved ? 'same' : inheritedStyle,
    if (styleReplacesInherited != null) 'styleReplaces': styleReplacesInherited,
    if (keys.isNotEmpty) 'keys': [for (var key in keys) key.toJson()],
    if (unkeyedText.isNotEmpty) 'unkeyed': unkeyedText,
    if (textOverflowed) 'overflowed': true,
    if (layout != null) 'layout': layout!.toJson(),
    if (label != null) 'label': label,
    if (selected != null) 'selected': selected,
    if (elidedChildren > 0) 'elided': elidedChildren,
    if (children.isNotEmpty)
      'children': [for (var child in children) child.toJson()],
  };

  /// This node in the compact spelling — see [InspectTree.toJson].
  ///
  /// [files] is grown as the walk finds new ones, so the table comes out in
  /// first-seen order and every index in it is one a node used.
  Map<String, Object?> _toCompactJson(String parentId, Map<String, int> files) {
    var own = parentId.isNotEmpty && id.startsWith('$parentId/')
        ? id.substring(parentId.length + 1)
        : id;
    return {
      'id': own,
      'type': type,
      if (description != null) 'description': description,
      if (widgetKey != null) 'widgetKey': widgetKey,
      if (source case var source?)
        'source':
            '${files.putIfAbsent(source.file, () => files.length)}'
            ':${source.line}:${source.column}',
      'local': createdByLocalProject,
      if (offstage) 'offstage': true,
      if (properties.isNotEmpty) 'properties': properties,
      if (textStyle.isNotEmpty) 'style': textStyle,
      // `"same"` rather than the whole map again — see [_readInherited].
      if (inheritedStyle.isNotEmpty)
        'inherited': _sameAsResolved ? 'same' : inheritedStyle,
      if (styleReplacesInherited != null)
        'styleReplaces': styleReplacesInherited,
      if (layout != null) 'layout': _rounded(layout!.toJson()),
      if (label != null) 'label': label,
      if (selected != null) 'selected': selected,
      if (elidedChildren > 0) 'elided': elidedChildren,
      if (children.isNotEmpty)
        'children': [
          for (var child in children) child._toCompactJson(id, files),
        ],
    };
  }

  static Map<String, Object?> _rounded(Map<String, Object?> json) => {
    for (var entry in json.entries)
      entry.key: switch (entry.value) {
        double value => _round(value),
        Map nested => _rounded(nested.cast<String, Object?>()),
        var other => other,
      },
  };

  /// Two decimals, and whole numbers without the `.0` — the same notation
  /// [InspectConstraints._n] settled on, for the same reason: `573.0` and
  /// `573` in one reply read as two different kinds of measurement.
  static num _round(double value) {
    var rounded = (value * 100).roundToDouble() / 100;
    return rounded == rounded.roundToDouble() ? rounded.toInt() : rounded;
  }

  InspectNode _with({List<InspectNode>? children, int? elidedChildren}) =>
      InspectNode(
        id: id,
        type: type,
        description: description,
        widgetKey: widgetKey,
        source: source,
        createdByLocalProject: createdByLocalProject,
        offstage: offstage,
        properties: properties,
        textStyle: textStyle,
        inheritedStyle: inheritedStyle,
        styleReplacesInherited: styleReplacesInherited,
        keys: keys,
        unkeyedText: unkeyedText,
        textOverflowed: textOverflowed,
        layout: layout,
        label: label,
        selected: selected,
        children: children ?? this.children,
        elidedChildren: elidedChildren ?? this.elidedChildren,
      );

  /// Whether this node and [other] occupy the very same box under the very
  /// same constraints — the test for "one of these two is scaffolding".
  ///
  /// Two nodes with no layout at all count as the same: neither has a box, so
  /// neither can be the one that explains where anything is.
  bool _sameBox(InspectNode other) {
    var mine = layout;
    var theirs = other.layout;
    if (mine == null || theirs == null) return mine == null && theirs == null;
    return mine.sameAs(theirs);
  }

  /// How much this node would be missed, used only to pick which node of a
  /// single-box chain to keep.
  ///
  /// Not a measure of importance in general — a `Text` that lost to nothing
  /// still scores 8. It ranks *rivals for one box*, which is why words and
  /// flex outrank everything: they are the two things no sibling in the chain
  /// can be carrying too.
  int get _weight {
    var weight = 0;
    // `Text("Save")` — the only kind of description the walk mints, and the
    // words are why anyone reads a tree.
    if (description != null && description!.contains('"')) weight += 8;
    // A Row is never scaffolding: `crossAxisAlignment` is the answer to half
    // the layout questions asked of a tree, and only this node has it.
    if (layout?.flex != null) weight += 8;
    if (properties.isNotEmpty) weight += 2;
    if (!_scaffolding.contains(_bareType) && !type.startsWith('_')) weight += 1;
    return weight;
  }

  /// The type without its generics — `NotificationListener` for a
  /// `NotificationListener<ScrollNotification>`, which is how it is spelled in
  /// [_scaffolding] and how anyone would have written the name.
  String get _bareType {
    var at = type.indexOf('<');
    return at < 0 ? type : type.substring(0, at);
  }

  /// Widgets that wrap without saying anything a reader can act on.
  ///
  /// They are not *dropped* for being on this list — a node is only ever
  /// dropped for sharing another node's box, and this list breaks the tie
  /// about which of the two goes. It matters because the loser's name is what
  /// survives into the reply: with `Gap` on the list, a spacer reads as
  /// `SizedBox(width: 8.0)` rather than as a bare `Gap` with the measurement
  /// thrown away.
  ///
  /// `Expanded` and `Flexible` are here for a sharper reason: what they do to
  /// a child is reported *on the child*, as [InspectLayout.flexFactor] and
  /// [InspectLayout.flexFit], read off its parent data. Keeping the wrapper as
  /// well would be reporting the same fact twice.
  static const _scaffolding = {
    'MouseRegion',
    'GestureDetector',
    'RawGestureDetector',
    'Listener',
    'Semantics',
    'ExcludeSemantics',
    'MergeSemantics',
    'BlockSemantics',
    'Focus',
    'FocusScope',
    'FocusTraversalGroup',
    'RepaintBoundary',
    'KeyedSubtree',
    'NotificationListener',
    'Builder',
    'AnimatedBuilder',
    'ListenableBuilder',
    'ValueListenableBuilder',
    'LayoutBuilder',
    'Expanded',
    'Flexible',
    // Not a framework widget, but `package:gap` is in enough Flutter apps to
    // be worth naming: every `Gap` is a `SizedBox` wearing a hat.
    'Gap',
  };

  /// This subtree with the scaffolding taken out — see [InspectFilter.noise].
  InspectNode _withoutScaffolding() {
    var children = [
      for (var child in this.children) child._withoutScaffolding(),
    ];
    if (children.length == 1 && _sameBox(children.single)) {
      var child = children.single;
      // Ties go to this node rather than the child: it is the outer one, so
      // its source is the call site the author wrote rather than a line inside
      // whatever it built.
      if (child._weight > _weight) return child;
      return _with(children: child.children, elidedChildren: 0);
    }
    return _with(children: children);
  }

  /// This subtree cut to [depth] more levels, marking what the cut removed.
  InspectNode _toDepth(int depth) {
    if (depth <= 0) {
      return _with(children: const [], elidedChildren: children.length);
    }
    return _with(children: [for (var c in children) c._toDepth(depth - 1)]);
  }
}

/// How much of a tree a caller wants.
///
/// Every field narrows what is *reported*, never what is walked. The walk
/// costs the same either way — the ids are positions in the whole tree and
/// have to stay that way, or a node id from one read would not name the same
/// node in the next. So this is about the size of the answer, which on a real
/// screen is the thing that was unusable: one observation of the flutterware
/// GUI's own Changes screen came back as 482 nodes and blew a 50,000-token
/// budget without reaching the bottom of the left pane.
class InspectFilter {
  const InspectFilter({this.root, this.maxDepth, this.noise = true});

  /// Report this node and its descendants instead of the whole tree.
  ///
  /// An [InspectNode.id] from an earlier read of the same screen. Unknown ids
  /// are refused rather than approximated, for the reason [InspectTree.nodeAt]
  /// gives: an id names a position, and a position that moved holds something
  /// else now.
  final String? root;

  /// How many levels below the reported root to include. Null is all of them.
  ///
  /// Counted over the tree *after* [noise] has run, because that is the tree
  /// the caller is looking at: on the Changes screen the app's own content
  /// starts nineteen wrappers down, and a depth counted before the filter
  /// would spend every level of the budget on them.
  final int? maxDepth;

  /// Drop widgets that share their only child's box, keeping whichever of the
  /// two carries more (see [InspectNode._weight]). On by default.
  ///
  /// This is where the bulk goes, and it is not a heuristic about importance:
  /// two nodes with byte-identical geometry are one thing on the screen
  /// described twice, and a reader can act on the description only once. Every
  /// surviving node is a real node with its real id, type, source and
  /// properties — nothing is merged or invented — so the reply stays a subset
  /// of the full tree rather than a rendering of it. Measured on the Changes
  /// screen: 436 nodes to 252, with `MouseRegion`, `GestureDetector`, `Gap`,
  /// `Expanded`, `InkWell` and `Builder` gone entirely.
  ///
  /// A dropped node takes its level with it, not its subtree. Its children
  /// are hoisted to its parent, so ids stay what they always were and a child
  /// may now sit under a node that is not its parent — `0/3/1/0/2` directly
  /// under `0/3`. Ask for `noise: false` to see the levels in between.
  final bool noise;

  static const none = InspectFilter(noise: false);

  bool get isEmpty => root == null && maxDepth == null && !noise;
}

/// A rendered diagnostic value, cut down to what a reader can use.
///
/// Two cuts, in this order and for this reason:
///
/// 1. **Colours become hex.** The framework describes one as
///    `Color(alpha: 1.0000, red: 0.4196, green: 0.4471, blue: 0.5020,
///    colorSpace: ColorSpace.sRGB)` — 91 characters that every reader has to
///    multiply by 255 to learn is `#6B7280`. They were 7.6 KB of one 234 KB
///    read, across 84 properties.
/// 2. **What is still too long keeps its head.** The elision used to take the
///    middle, which on the values that actually overflow ate the payload and
///    kept the boilerplate: `BoxDecoration(color: Color(alpha: 1.0000, red:  …
///    ircular(7.0), topRight: Radius.circular(7.0)))` — the colour, the one
///    thing being asked about, is what the ellipsis removed.
///
/// Colours first is what makes the second cut rare: most of the values that
/// overflowed did so because they had a colour spelled out inside them, and
/// once it is six characters the whole value fits.
String shortenPropertyValue(String value) {
  // A quoted value is somebody's own words — a `Text`'s data, a hint, a label
  // — and `describeIdentity` never renders one. An order number that reads
  // `"Order#12345"` is content, and editing the app's content out of its own
  // report would be worse than the noise this is removing.
  var short = _quotedValue.hasMatch(value) ? value : withoutIdentityHash(value);
  short = short.replaceAllMapped(_colorPattern, _hexColor);
  if (short.length <= _maxPropertyLength) return short;
  return '${short.substring(0, _maxPropertyLength - 1)}…';
}

final _quotedValue = RegExp(r'^".*"$', dotAll: true);

const _maxPropertyLength = 96;

final _colorPattern = RegExp(
  r'Color\(alpha: ([\d.]+), red: ([\d.]+), green: ([\d.]+), blue: ([\d.]+)'
  r'(?:, colorSpace: ColorSpace\.(\w+))?\)',
);

/// `#RRGGBB`, with CSS's trailing alpha pair when it is not opaque and the
/// colour space appended when it is not the one everybody assumes.
String _hexColor(Match match) {
  String channel(String? value) => ((double.tryParse(value ?? '') ?? 0) * 255)
      .round()
      .clamp(0, 255)
      .toRadixString(16)
      .padLeft(2, '0')
      .toUpperCase();
  var alpha = double.tryParse(match[1] ?? '') ?? 1;
  var space = match[5];
  return '#${channel(match[2])}${channel(match[3])}${channel(match[4])}'
      '${alpha >= 1 ? '' : channel(match[1])}'
      '${space == null || space == 'sRGB' ? '' : ' $space'}';
}

/// One entry's tree, as of one build of it.
class InspectTree {
  const InspectTree({required this.entryId, this.root, this.format});

  /// Reads either spelling — see [toJson] for what `compact` changes and why
  /// a reader has to know both.
  factory InspectTree.fromJson(Map<String, Object?> json) {
    var root = switch (json['root']) {
      Map root => root.cast<String, Object?>(),
      _ => null,
    };
    var format = json['format'] as int?;
    if (root == null) {
      return InspectTree(entryId: json['entry'] as String?, format: format);
    }
    return InspectTree(
      entryId: json['entry'] as String?,
      format: format,
      root: json['compact'] == true
          ? _readCompact(root, '', [
              for (var file in json['files'] as List? ?? const []) '$file',
            ])
          : InspectNode.fromJson(root),
    );
  }

  /// The compact spelling, expanded back into ordinary nodes.
  ///
  /// Ids come back absolute and sources come back with their whole path, so
  /// nothing downstream of here can tell which spelling arrived.
  static InspectNode _readCompact(
    Map<String, Object?> json,
    String parentId,
    List<String> files,
  ) {
    var own = json['id'] as String? ?? '';
    var id = parentId.isEmpty || own.isEmpty ? own : '$parentId/$own';
    var textStyle = switch (json['style']) {
      Map style => style.cast<String, String>(),
      _ => const <String, String>{},
    };
    return InspectNode(
      id: id,
      type: json['type'] as String? ?? '',
      description: json['description'] as String?,
      widgetKey: json['widgetKey'] as String?,
      createdByLocalProject: json['local'] as bool? ?? false,
      offstage: json['offstage'] as bool? ?? false,
      elidedChildren: json['elided'] as int? ?? 0,
      label: json['label'] as String?,
      selected: json['selected'] as bool?,
      properties: switch (json['properties']) {
        Map properties => properties.cast<String, String>(),
        _ => const {},
      },
      textStyle: textStyle,
      inheritedStyle: InspectNode._readInherited(json['inherited'], textStyle),
      styleReplacesInherited: json['styleReplaces'] as bool?,
      layout: switch (json['layout']) {
        Map layout => InspectLayout.fromJson(layout.cast<String, Object?>()),
        _ => null,
      },
      source: switch (json['source']) {
        String source => _readCompactSource(source, files),
        // Tolerated rather than expected: a guest that spelled the tree
        // compact but the source long is not a shape this ever writes, and
        // dropping the location over that would be losing the one field that
        // says where the widget came from.
        Map source => InspectSource.fromJson(source.cast<String, Object?>()),
        _ => null,
      },
      children: [
        for (var child in json['children'] as List? ?? const [])
          if (child is Map)
            _readCompact(child.cast<String, Object?>(), id, files),
      ],
    );
  }

  /// `3:402:11` against the tree's file table.
  static InspectSource? _readCompactSource(String source, List<String> files) {
    var parts = source.split(':');
    if (parts.length != 3) return null;
    var file = int.tryParse(parts[0]);
    if (file == null || file < 0 || file >= files.length) return null;
    return InspectSource(
      file: files[file],
      line: int.tryParse(parts[1]) ?? 0,
      column: int.tryParse(parts[2]) ?? 0,
    );
  }

  static const empty = InspectTree(entryId: null, root: null);

  /// Which entry this is of.
  ///
  /// The same warning as `KnobReport.entryId`: a tree naming another entry is
  /// a read that landed before the switch did, not an empty one.
  final String? entryId;

  /// Null when the guest has not built yet — a headless host draws nothing
  /// until a frame is asked for, so a tree read before one is an answer about
  /// nothing rather than an error.
  final InspectNode? root;

  /// Which way of describing a widget produced this tree — see
  /// `GuestInspector.treeFormat`. Null for a tree read before formats were
  /// recorded, or read by something other than the guest's own walk.
  ///
  /// What lets a comparison tell a changed widget from a changed *reader*. Its
  /// two sides are captured by two checkouts' own `package:flutterware`, and
  /// a version that learned to spell `Text.rich` as `Text("…")` reported every
  /// one of them as changed against the version before it — a hundred rows
  /// on a branch that only bumped the dependency, and not one pixel moved.
  final int? format;

  /// Every node, depth-first, root included.
  Iterable<InspectNode> get nodes sync* {
    Iterable<InspectNode> walk(InspectNode node) sync* {
      yield node;
      for (var child in node.children) {
        yield* walk(child);
      }
    }

    if (root case var root?) yield* walk(root);
  }

  /// [nodes], minus offstage subtrees — pruned at the flagged node rather than
  /// filtered per node, because a subtree's descendants do not repeat the flag.
  Iterable<InspectNode> get _onstage sync* {
    Iterable<InspectNode> walk(InspectNode node) sync* {
      if (node.offstage) return;
      yield node;
      for (var child in node.children) {
        yield* walk(child);
      }
    }

    if (root case var root?) yield* walk(root);
  }

  int get length => nodes.length;

  /// The deepest node whose box contains ([x], [y]), in the guest's own
  /// coordinates.
  ///
  /// An approximation of a hit test, deliberately. It knows only
  /// rectangles: not transforms, not clips, not opacity, not `IgnorePointer`,
  /// and of two overlapping boxes at the same depth it takes the later, which
  /// is a guess at paint order rather than knowledge of it.
  ///
  /// That is the right trade for a *pointer*. Following the mouse means
  /// answering every frame, where a round trip per move would stutter and being
  /// one node out for a moment costs nothing. Anything that has to be right —
  /// what a click actually selected — asks the guest, which runs the
  /// framework's own `hitTest` over the real render tree.
  ///
  /// Nodes with no box are skipped rather than treated as empty: a provider or
  /// a builder lays nothing out, and its child is the thing under the cursor.
  /// Every node is considered rather than only the children of one that
  /// contains the point, because a child can be laid out beyond its parent —
  /// which is what an overflow *is*, and an overflowing widget is exactly what
  /// a pointer tends to be aimed at.
  ///
  /// Offstage nodes are skipped too, subtree and all: a route kept alive under
  /// the current one holds its old rects, which overlap the screen — and being
  /// deeper, they *won* here, so picking on a screenshot could select a widget
  /// from the previous screen. What is not on the picture cannot be what the
  /// pointer means.
  InspectNode? nodeAtPoint(double x, double y) {
    InspectNode? best;
    var bestDepth = -1;
    for (var node in _onstage) {
      var layout = node.layout;
      if (layout == null) continue;
      if (x < layout.x || y < layout.y) continue;
      if (x >= layout.x + layout.width || y >= layout.y + layout.height) {
        continue;
      }
      // `>=` rather than `>`: depth-first order visits later siblings last, so
      // ties go to whichever was drawn on top.
      var depth = node.id.isEmpty ? 0 : node.id.split('/').length;
      if (depth >= bestDepth) {
        best = node;
        bestDepth = depth;
      }
    }
    return best;
  }

  /// The node with [id], or null.
  ///
  /// Null rather than a nearest match on purpose. A structural id points at a
  /// position, and a caller that edited the demo between two calls is asking
  /// about a position that may now hold something else — answering with
  /// whatever moved into it would be a confident wrong answer. The caller
  /// re-reads the tree.
  /// Nodes whose type, description or semantics label contains [query],
  /// case-insensitively.
  ///
  /// What to reach for instead of reading a tree, and the measurement is
  /// lopsided enough to be worth stating: `find "Watching"` answers "what
  /// colour and size is that label" in 131 tokens where the whole tree is
  /// 19 500. It is also the way out of the `treeRoot` chicken-and-egg — an id
  /// is a position, so you needed a tree to get one, and now you do not.
  ///
  /// The label is searched as well as the words, so `find "Tab 1 of 2"` reaches
  /// what Flutter says about a control rather than only what it draws.
  Iterable<InspectNode> matching(String query) sync* {
    var needle = query.toLowerCase();
    for (var node in nodes) {
      if (node.type.toLowerCase().contains(needle) ||
          (node.description?.toLowerCase().contains(needle) ?? false) ||
          (node.label?.toLowerCase().contains(needle) ?? false)) {
        yield node;
      }
    }
  }

  /// Every on-stage node whose box contains ([x], [y]), outermost first.
  ///
  /// The *chain*, not the innermost hit, because the thing under a cursor is
  /// usually a `Text` and the thing you meant is the button around it — and
  /// because the chain is where the layout answer is: the `Row` three levels
  /// out is what has the `crossAxisAlignment`.
  ///
  /// Rectangles only, like [nodeAtPoint]: no transforms, no clips. Run it over
  /// a [filtered] tree — measured, the unfiltered chain is 35 nodes of which 20
  /// are the same root wrapper run present under every point on every screen.
  List<InspectNode> chainAt(double x, double y) => [
    for (var node in _onstage)
      if (node.layout case var layout?)
        if (x >= layout.x &&
            y >= layout.y &&
            x < layout.x + layout.width &&
            y < layout.y + layout.height)
          node,
  ];

  /// Every distinct text style on screen, most-used first.
  ///
  /// An aggregate, because "what is the type ramp" is a table and not a list
  /// of nodes. Asking it as a search returned 63 hits, cost 2451 tokens and
  /// was still truncated; this is the whole answer in about 185 — which makes
  /// it the cheapest question in the drill-down and the one that settles most
  /// design arguments (two greys that should be one, a ramp with 11.5 *and*
  /// 12.5 in it).
  ///
  /// Buckets on [InspectNode.textStyle], and that is a correction. It used
  /// to read [InspectNode.properties], which for a `Text` is the style its
  /// author wrote — so every text that took its size and colour from the theme
  /// had neither key and fell out of the ramp entirely. In a themed app that is
  /// most of the screen, and the answer was a table of the exceptions
  /// presented as a table of the whole. A ramp that cannot see the body text
  /// cannot settle "are these two greys the same grey", which is the question
  /// it exists for.
  ///
  /// The fallback to `properties` is for stored readings, not for live ones:
  /// scenario artifacts and comparison caches written before the resolved
  /// Every translation key on this screen, with where it is.
  ///
  /// Flattened out of the tree so a reader — the export, the panel — does not
  /// have to walk 120KB of nodes to answer "which keys are here". The node id
  /// and box ride along, because the next question is always where to crop.
  ///
  /// A key appearing twice on a screen appears twice here: two occurrences are
  /// two places to photograph, and collapsing them would throw away the choice
  /// between them.
  List<TranslationOccurrence> translationKeys() {
    var found = <TranslationOccurrence>[];
    void visit(InspectNode node) {
      for (var key in node.keys) {
        found.add(
          TranslationOccurrence(
            key: key,
            node: node.id,
            layout: node.layout,
            offstage: node.offstage,
            overflowed: node.textOverflowed,
          ),
        );
      }
      for (var child in node.children) {
        visit(child);
      }
    }

    if (root case var root?) visit(root);
    return found;
  }

  /// Every span on this screen that no catalog claimed, with where it is.
  ///
  /// The other half of [translationKeys], and deliberately *not* called a list
  /// of untranslated strings: most of it has no key by construction — a
  /// formatted date, a name, a number read off a fixture. Classifying it is the
  /// reader's job, and the source location is there so the reader can do it.
  List<UnkeyedText> unkeyedText() {
    var found = <UnkeyedText>[];
    void visit(InspectNode node) {
      for (var text in node.unkeyedText) {
        found.add(
          UnkeyedText(
            text: text,
            node: node.id,
            layout: node.layout,
            source: node.source,
            offstage: node.offstage,
          ),
        );
      }
      for (var child in node.children) {
        visit(child);
      }
    }

    if (root case var root?) visit(root);
    return found;
  }

  /// style existed have only the old keys, and a ramp of the exceptions still
  /// beats an empty table when reopening an old run.
  List<InspectStyle> styles() {
    var buckets = <String, InspectStyle>{};
    for (var node in _onstage) {
      var properties = node.textStyle.isNotEmpty
          ? node.textStyle
          : node.properties;
      if (properties['size'] == null && properties['color'] == null) continue;
      // Text nodes only: a `size` on something that draws no words is a
      // different measurement wearing the same name.
      if (node.description?.contains('"') != true) continue;
      var style = InspectStyle(
        size: properties['size'],
        weight: properties['weight'],
        color: properties['color'],
        count: 1,
        sample: _words(node) ?? '',
      );
      var existing = buckets[style.key];
      buckets[style.key] = existing == null
          ? style
          : existing.plusOne(style.sample);
    }
    return buckets.values.toList()..sort((a, b) => b.count.compareTo(a.count));
  }

  /// `Text("Save")` → `Save`, or null when the node draws no words.
  static String? _words(InspectNode node) {
    var description = node.description;
    if (description == null) return null;
    var open = description.indexOf('"');
    var close = description.lastIndexOf('"');
    if (open == -1 || close <= open) return null;
    var words = description.substring(open + 1, close);
    return words.isEmpty ? null : words;
  }

  InspectNode? nodeAt(String id) {
    for (var node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  /// Every node [selector] could mean — an **id** first, then a name matched
  /// the way [matching] matches.
  ///
  /// One list rather than one node, because how to answer "several" is up to
  /// the caller and differs per call site: a crop refuses and lists them, a
  /// tree read might narrow to the outermost. What is not the caller's
  /// business is the *rule* — an id is exact and a name is a search — and
  /// having that written once is why this is here rather than in each of them.
  ///
  /// An id wins outright when it hits: ids are positions like `0/3/1/0` and no
  /// widget is called that, so the two vocabularies do not collide in practice
  /// — and if one ever did, the exact answer is the right one.
  List<InspectNode> resolve(String selector) {
    var exact = nodeAt(selector);
    return exact != null ? [exact] : matching(selector).toList();
  }

  /// This tree, narrowed to what [filter] asks for.
  ///
  /// Throws when [InspectFilter.root] names no node, for the reason
  /// [nodeAt] gives: answering about whatever moved into that position would
  /// be a confident wrong answer.
  InspectTree filtered(InspectFilter filter) {
    if (filter.isEmpty || root == null) return this;
    var from = root!;
    if (filter.root case var id? when id.isNotEmpty) {
      var found = nodeAt(id);
      if (found == null) {
        throw ArgumentError(
          'no node "$id" in this tree — ids are positions in the tree as it '
          'was when you read it, so one from an older screen names nothing '
          'here. Observe again and take the id from that reply.',
        );
      }
      from = found;
    }
    if (filter.noise) from = from._withoutScaffolding();
    if (filter.maxDepth case var depth?) from = from._toDepth(depth);
    return InspectTree(entryId: entryId, root: from, format: format);
  }

  /// The tree as JSON, in one of two spellings.
  ///
  /// Verbose is the original and the default: every node's id absolute, every
  /// source its own object with a whole `file://` path. It is what the panel,
  /// the scenario artifacts and the comparison caches have always been written
  /// in, and changing it under them would be changing files already on disk.
  ///
  /// Compact is the same tree written for a reader that pays per byte. Two
  /// substitutions, both undone by [fromJson] before anything downstream sees
  /// a node:
  ///
  /// - **Ids relative to the parent.** A node twenty levels down spells its id
  ///   `0/0/0/0/0/0/0/0/0/0/0/0/0/0/0/0/0/0/1/0` and its child spells the same
  ///   twenty characters again plus one. Measured: 34 KB of a 234 KB read, for
  ///   a prefix the reader already has.
  /// - **A file table.** 436 nodes of the Changes screen named 13 distinct
  ///   files between them, and repeated the absolute path of one on every
  ///   node: 71 KB, 30% of the read, to say `changes_screen.dart` 153 times.
  ///   Compact writes `files` once and `"source": "0:402:11"` per node.
  ///
  /// Sub-pixel geometry is rounded to two decimals here too — `7.26` rather
  /// than `7.261507987976074`. Only in this spelling: the comparison caches
  /// diff trees field by field and a rounded number would read as a change.
  Map<String, Object?> toJson({bool compact = false}) {
    if (!compact) {
      return {'entry': entryId, 'format': ?format, 'root': root?.toJson()};
    }
    var files = <String, int>{};
    var written = root?._toCompactJson('', files);
    return {
      'entry': entryId,
      'format': ?format,
      'compact': true,
      // Filled by the walk above, so it is read after it.
      'files': [for (var file in files.keys) file],
      'root': written,
    };
  }
}

/// One distinct text style on a screen, and how many things wear it.
///
/// The unit of [InspectTree.styles]. Deliberately three fields and a count
/// rather than a whole `TextStyle`: the questions this answers — "is the ramp
/// consistent", "are these two greys the same grey", "what is the heading" —
/// are all about size, weight and colour, and everything else is what the
/// per-node `properties` are for.
class InspectStyle {
  const InspectStyle({
    this.size,
    this.weight,
    this.color,
    required this.count,
    required this.sample,
  });

  final String? size;
  final String? weight;
  final String? color;

  /// How many texts on this screen have exactly this size/weight/colour.
  final int count;

  /// One of them, so a row can be recognised without looking it up.
  final String sample;

  String get key => '${size ?? '?'}/${weight ?? '?'}/${color ?? '?'}';

  InspectStyle plusOne(String other) => InspectStyle(
    size: size,
    weight: weight,
    color: color,
    count: count + 1,
    // The first one seen stays: it is the one nearest the top of the screen,
    // which is the one a reader is most likely to recognise.
    sample: sample.isEmpty ? other : sample,
  );

  Map<String, Object?> toJson() => {
    if (size != null) 'size': size,
    if (weight != null) 'weight': weight,
    if (color != null) 'color': color,
    'count': count,
    if (sample.isNotEmpty) 'sample': sample,
  };

  static InspectStyle fromJson(Map<String, Object?> json) => InspectStyle(
    size: json['size'] as String?,
    weight: json['weight'] as String?,
    color: json['color'] as String?,
    count: json['count'] as int? ?? 0,
    sample: json['sample'] as String? ?? '',
  );
}
