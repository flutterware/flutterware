/// A screen as something to act on, rather than a tree to read.
///
/// Plain Dart, like `node.dart` and for the same reason — `fw` and the MCP
/// server link this. It is a **pure function of an [InspectTree]**
/// ([Screen.of]), which is what lets run, previews and scenarios all hand back
/// the same thing without three implementations: each surface's job is to
/// produce a tree, and this turns it into a screen.
library;

import 'package:meta/meta.dart';

import 'node.dart';

/// Widget types that mean "a person can do something here".
///
/// A list rather than a signal read off the widget, because there is no signal
/// to read: a callback is not in the diagnostics, and the semantics `tap`
/// action belongs to whichever node the render tree hung it on rather than to
/// the widget a reader would name.
const _interactive = {
  'ElevatedButton',
  'TextButton',
  'OutlinedButton',
  'FilledButton',
  'IconButton',
  'FloatingActionButton',
  'CupertinoButton',
  'BackButton',
  'CloseButton',
  'InkWell',
  'InkResponse',
  'GestureDetector',
  'RawGestureDetector',
  'Checkbox',
  'CheckboxListTile',
  'Radio',
  'RadioListTile',
  'Switch',
  'SwitchListTile',
  'Slider',
  'TextField',
  'TextFormField',
  'EditableText',
  'DropdownButton',
  'DropdownMenu',
  'PopupMenuButton',
  'MenuItemButton',
  'SubmenuButton',
  'Tab',
  'ListTile',
  'Chip',
  'ActionChip',
  'InputChip',
  'FilterChip',
  'ChoiceChip',
  'SegmentedButton',
  'ToggleButtons',
  'Draggable',
  'Dismissible',
  'ExpansionTile',
  'NavigationDestination',
  'NavigationRailDestination',
};

const _fields = {'TextField', 'TextFormField', 'EditableText'};

bool _scrolls(String type) =>
    type.contains('ListView') ||
    type.contains('GridView') ||
    type.contains('ScrollView') ||
    type.contains('PageView') ||
    type == 'Scrollable' ||
    type == 'ReorderableListView';

String _bare(String type) {
  var angle = type.indexOf('<');
  return angle == -1 ? type : type.substring(0, angle);
}

/// One thing on a screen: something a person can act on, or words they read.
class ScreenItem {
  const ScreenItem({
    required this.n,
    required this.role,
    required this.box,
    this.words,
    this.selected,
    this.enabled = true,
    this.children = const [],
  });

  factory ScreenItem.fromJson(Map<String, Object?> json) => ScreenItem(
    n: json['n'] as int? ?? 0,
    role: json['role'] as String? ?? 'text',
    words: json['w'] as String?,
    box: [for (var v in json['box'] as List? ?? const []) (v as num).toInt()],
    selected: json['sel'] as bool?,
    enabled: json['off'] != true,
    children: [
      for (var child in json['has'] as List? ?? const [])
        ScreenItem.fromJson((child as Map).cast<String, Object?>()),
    ],
  );

  /// This item's number in the screen, counted in reading order.
  ///
  /// A position in this reply, not an identity that outlives it. There is
  /// deliberately no node id here: an id is a position in a tree that has since
  /// moved, and a re-query against a live app answers with today's geometry
  /// under yesterday's name. Drill down by [box] centre with `at`, or by words
  /// with `find` — both resolve against the screen as it is now.
  final int n;

  /// `button`, `field` or `text`.
  final String role;

  /// What it says — the semantics label where the app provided one, otherwise
  /// the words inside it, otherwise its tooltip. Null for a control that
  /// carries none of the three, which is an accessibility bug worth seeing.
  final String? words;

  /// `[x, y, width, height]`, rounded to whole logical pixels.
  final List<int> box;

  /// Whether this is the current one of its group, when anything said so.
  /// Null means nothing said — see [InspectNode.selected].
  final bool? selected;

  final bool enabled;

  /// Controls inside this one — a close button on a tab, a checkbox in a row.
  ///
  /// Words are rolled *up* into their control, so nothing here is text; what
  /// nests is a second thing to press. It has to be reported: an item that
  /// swallowed another item left a hole in the numbering and hid a control the
  /// agent could see in the screenshot and not in the reply.
  final List<ScreenItem> children;

  bool get isControl => role != 'text';

  /// This item and every control inside it.
  Iterable<ScreenItem> get selfAndDescendants sync* {
    yield this;
    for (var child in children) {
      yield* child.selfAndDescendants;
    }
  }

  Map<String, Object?> toJson() => {
    'n': n,
    'role': role,
    if (words != null) 'w': words,
    'box': box,
    if (selected != null) 'sel': selected,
    if (!enabled) 'off': true,
    if (children.isNotEmpty)
      'has': [for (var child in children) child.toJson()],
  };
}

/// A branch point in the layout — a pane, a bar, a list.
///
/// Not a named widget: it is where the screen's items *fork*, which is what
/// makes the reply read as a layout rather than as a list. See
/// [Screen.of].
class ScreenRegion {
  const ScreenRegion({
    required this.label,
    required this.box,
    required this.children,
    this.scrolls = false,
  });

  factory ScreenRegion.fromJson(Map<String, Object?> json) => ScreenRegion(
    label: json['in'] as String? ?? '',
    box: [for (var v in json['box'] as List? ?? const []) (v as num).toInt()],
    scrolls: json['scrolls'] as bool? ?? false,
    children: [
      for (var child in json['has'] as List? ?? const [])
        (child as Map).containsKey('in')
            ? ScreenRegion.fromJson(child.cast<String, Object?>())
            : ScreenItem.fromJson(child.cast<String, Object?>()),
    ],
  );

  /// `Column @ shell_view.dart:185` — the widget type and where it was built.
  /// No naming heuristic: the file and line are how a reader gets from "the
  /// nav rail" to the code that made it.
  final String label;
  final List<int> box;

  /// Whether this region scrolls. Reported because it is the answer to a
  /// question every caller has and `scrollTo` needs, and because it is why a
  /// region survives thinning that would otherwise remove it.
  final bool scrolls;

  /// [ScreenRegion] or [ScreenItem], in reading order.
  final List<Object> children;

  Map<String, Object?> toJson() => {
    'in': label,
    'box': box,
    if (scrolls) 'scrolls': true,
    'has': [
      for (var child in children)
        child is ScreenRegion ? child.toJson() : (child as ScreenItem).toJson(),
    ],
  };
}

/// What one settled moment of an app looks like, in about a twentieth of the
/// tokens its widget tree costs.
class Screen {
  const Screen({this.root, this.items = const []});

  factory Screen.fromJson(Map<String, Object?> json) {
    var root = switch (json['screen']) {
      Map region => ScreenRegion.fromJson(region.cast<String, Object?>()),
      _ => null,
    };
    var items = <ScreenItem>[];
    void walk(Object node) {
      if (node is ScreenItem) {
        items.addAll(node.selfAndDescendants);
      } else if (node is ScreenRegion) {
        node.children.forEach(walk);
      }
    }

    if (root != null) walk(root);
    return Screen(root: root, items: items);
  }

  /// The layout, nested. Null when nothing on screen was worth reporting.
  final ScreenRegion? root;

  /// Every item, flat and in reading order — the same objects the tree holds,
  /// for a caller that wants to look one up by [ScreenItem.n].
  final List<ScreenItem> items;

  int get length => items.length;

  /// Controls that carry no words at all.
  ///
  /// Surfaced rather than tolerated: a control with no label, no text and no
  /// tooltip cannot be targeted by an agent *or* announced by a screen reader,
  /// so counting them is both a caveat on this reply and a real finding about
  /// the app.
  int get anonymousControls =>
      items.where((i) => i.isControl && i.words == null).length;

  Map<String, Object?> toJson() => {
    if (root != null) 'screen': root!.toJson(),
    'items': items.length,
    if (anonymousControls > 0) 'anonymous': anonymousControls,
  };

  /// [of], for a caller whose answer is worth more than its screen.
  ///
  /// A projection is a decoration on an observation, and a decoration may
  /// not take the observation down. Measured the hard way: one `.single`
  /// over a fork that had two children turned every `act` on a perfectly
  /// ordinary screen into `Bad state: Too many elements` — no verb result, no
  /// picture, no journal entry, and a message naming neither the screen nor
  /// the projection it came out of. The verb had landed; the reply said
  /// nothing at all.
  ///
  /// So every surface projects through here, and a screen that cannot be
  /// built rides a note beside the rest of the frame — the same way a refused
  /// `treeRoot` always did.
  static ({Screen? screen, String? note}) tryOf(
    InspectTree tree, {
    int minRegionItems = 3,
  }) {
    try {
      if (debugFailProjection case var failure?) {
        return (screen: null, note: projectionFailed(failure));
      }
      return (screen: of(tree, minRegionItems: minRegionItems), note: null);
    } on Object catch (error) {
      return (screen: null, note: projectionFailed(error));
    }
  }

  /// Makes [tryOf] fail, for the tests of what the surfaces do when it does.
  ///
  /// A seam rather than a poisoned tree, because the projection is meant to
  /// have no input that breaks it — that is what the bug behind [tryOf] was.
  /// The degradation still has to be exercised: it is what a *future* one
  /// will cost.
  @visibleForTesting
  static Object? debugFailProjection;

  /// What a caller is told when [tryOf] could not build a screen.
  static String projectionFailed(Object error) =>
      'the screen could not be projected from this frame: $error. This is a '
      'bug in flutterware, not in the app, and worth reporting. The rest of '
      'this reply comes from the same frame and still works: the texts, the '
      'picture, `find "…"`, `at "x,y"` and `tree: true`. Only the numbering '
      'is missing, so `item:` has nothing to point at. Target by text, or by '
      '`at` with a point read off the picture.';

  /// The screen [tree] describes.
  ///
  /// Built from the unfiltered tree, which is not an oversight: the noise
  /// filter drops a node that shares its only child's box, and measured on the
  /// flutterware GUI that removes 29 of 32 interactive widgets — an `InkWell`
  /// carries neither words nor properties, so it loses every tie. The
  /// survivors are not the ones you tap.
  ///
  /// Three passes, each of which exists because a simpler version was measured
  /// and failed:
  ///
  /// 1. **Words, in order**: the semantics label, the node's own text, the
  ///    texts *geometrically inside* the control, the tooltip. Label-first
  ///    alone left every button on the Brewline menu anonymous, because
  ///    `InkWell` publishes `onTap` without merging its children's labels.
  ///    Containment is a property of the layout, which every app has.
  /// 2. **Regions**: prune to the items, collapse single-child chains, and
  ///    what survives is where the screen forks. Costs ~19% over a flat list
  ///    and is the difference between listing a screen and describing one.
  /// 3. **Thinning**: a region holding fewer than [minRegionItems] things is a
  ///    grouping nobody needed — except a scrollable, which is never thinned.
  ///
  /// Throws nothing an input can cause; [tryOf] is the total spelling for the
  /// surfaces, whose reply must survive a projection that fails anyway.
  static Screen of(InspectTree tree, {int minRegionItems = 3}) {
    var root = tree.root;
    if (root == null) return const Screen();

    // Pass 1 — the candidates, in tree order.
    var candidates = <_Candidate>[];
    // Folding offstage, and skipping the fold points themselves: a route kept
    // alive under the one covering it holds rects that overlap the screen, and
    // a screen listing things nobody can see or touch is worse than a short
    // one.
    for (var node in root.nodesFoldingOffstage) {
      if (node.offstage) continue;
      var layout = node.layout;
      if (layout == null || layout.width <= 0 || layout.height <= 0) continue;
      var bare = _bare(node.type);
      var control = _interactive.contains(bare);
      var text = _words(node);
      if (!control && text == null) continue;
      candidates.add(
        _Candidate(
          node: node,
          role: control
              ? (_fields.contains(bare) ? 'field' : 'button')
              : 'text',
          box: [
            layout.x.round(),
            layout.y.round(),
            layout.width.round(),
            layout.height.round(),
          ],
          text: text,
        ),
      );
    }

    // Roll texts up into the innermost control that holds them — **in the box
    // and under it in the tree**, both.
    //
    // Geometry alone is not enough, and the failure is not exotic: a row whose
    // box overflows its viewport reaches down over whatever is painted below,
    // and measured live one file row swallowed the address bar. Ancestry alone
    // is not enough either — that is what left the Brewline cards anonymous.
    // The tree says what belongs to what and the boxes say what is drawn
    // inside what; a text is a control's words only when both agree.
    var controls = [
      for (var c in candidates)
        if (c.role != 'text') c,
    ];
    var eaten = <_Candidate>{};
    for (var candidate in candidates) {
      if (candidate.role != 'text' || candidate.text == null) continue;
      _Candidate? owner;
      for (var control in controls) {
        if (identical(control, candidate)) continue;
        if (!_isUnder(candidate.node.id, control.node.id)) continue;
        if (!_holds(control.box, candidate.box)) continue;
        if (owner == null || _area(control.box) < _area(owner.box)) {
          owner = control;
        }
      }
      if (owner == null) continue;
      owner.swallowed.add(candidate.text!);
      eaten.add(candidate);
    }

    var kept = <String, _Candidate>{};
    var n = 0;
    for (var candidate in candidates) {
      if (eaten.contains(candidate)) continue;
      candidate.n = ++n;
      kept[candidate.node.id] = candidate;
    }
    if (kept.isEmpty) return const Screen();

    // Pass 2 — the regions.
    var pruned = _prune(root, kept);
    // Pass 3 — the thinning.
    if (pruned is _Region) pruned = _thin(pruned, minRegionItems);
    var region = pruned is _Region
        ? pruned.toRegion()
        // Everything on screen sits under one item: there is no fork, so there
        // is no layout to describe. Report the items under a root standing for
        // the whole tree rather than inventing a region.
        : ScreenRegion(
            label: _label(root),
            box: _boxOf(root) ?? const [0, 0, 0, 0],
            children: [if (pruned is _Candidate) pruned.toItem()],
          );
    return Screen(
      root: region,
      items: [
        for (var child in region.children)
          if (child is ScreenItem)
            ...child.selfAndDescendants
          else
            ..._itemsUnder(child as ScreenRegion),
      ],
    );
  }

  static Iterable<ScreenItem> _itemsUnder(ScreenRegion region) sync* {
    for (var child in region.children) {
      if (child is ScreenItem) {
        yield* child.selfAndDescendants;
      } else {
        yield* _itemsUnder(child as ScreenRegion);
      }
    }
  }

  static String? _words(InspectNode node) {
    var description = node.description;
    if (description == null) return null;
    var open = description.indexOf('"');
    var close = description.lastIndexOf('"');
    if (open == -1 || close <= open) return null;
    var words = description.substring(open + 1, close);
    return words.isEmpty ? null : words;
  }

  static int _area(List<int> box) => box[2] * box[3];

  /// Whether [id] is a descendant of [ancestor], read straight off the ids —
  /// which *are* the paths, so this is a prefix test and nothing more.
  static bool _isUnder(String id, String ancestor) =>
      ancestor.isEmpty ? id.isNotEmpty : id.startsWith('$ancestor/');

  static bool _holds(List<int> outer, List<int> inner) =>
      inner[0] >= outer[0] - 1 &&
      inner[1] >= outer[1] - 1 &&
      inner[0] + inner[2] <= outer[0] + outer[2] + 1 &&
      inner[1] + inner[3] <= outer[1] + outer[3] + 1;

  static List<int>? _boxOf(InspectNode node) {
    var layout = node.layout;
    if (layout == null) return null;
    return [
      layout.x.round(),
      layout.y.round(),
      layout.width.round(),
      layout.height.round(),
    ];
  }

  static String _label(InspectNode node) {
    var type = _bare(node.type);
    var source = node.source;
    if (source == null) return type;
    var file = source.file.split('/').last;
    return '$type @ $file:${source.line}';
  }

  /// The tree pruned to the items, with single-child chains collapsed. Returns
  /// a [_Region], a [ScreenItem], or null when this subtree holds neither.
  static Object? _prune(InspectNode node, Map<String, _Candidate> kept) {
    var children = <Object>[];
    for (var child in node.children) {
      var pruned = _prune(child, kept);
      if (pruned != null) children.add(pruned);
    }
    // An item takes over its subtree — but keeps the *controls* in it, flat.
    // Its words were rolled up in pass one so nothing here is text, and a
    // control inside a control is a second thing to press: swallowing it
    // silently left a hole in the numbering and hid a button the agent could
    // see in the screenshot and not in the reply.
    if (kept[node.id] case var candidate?) {
      candidate.nested.addAll(_itemsIn(children));
      return candidate;
    }
    if (children.isEmpty) return null;
    if (children.length == 1) return children.single;
    // A region is a box — it is how a reader locates the fork against the
    // picture — and a fork can happen at a node that has none: every sliver
    // is one, since its render object is a `RenderSliver` rather than a laid
    // out `RenderBox`. So a screen written as `CustomScrollView` + `SliverList`
    // forks where nothing carries a rect, and the pruner used to assert that
    // could not happen (`.single` over two children, which is a `StateError`
    // that took the whole observation down with it).
    //
    // What the children cover is the truthful answer to where the fork is:
    // the sliver's own extent is in a different space, and the region exists
    // to say "these things are grouped, here".
    return _Region(node, children, box: _boxOf(node) ?? _cover(children));
  }

  /// The box holding every one of [nodes] — items and regions both.
  static List<int> _cover(List<Object> nodes) {
    var left = 0, top = 0, right = 0, bottom = 0;
    var first = true;
    for (var node in nodes) {
      var box = switch (node) {
        _Candidate(:var box) => box,
        _Region(:var box) => box,
        _ => null,
      };
      if (box == null) continue;
      if (first) {
        left = box[0];
        top = box[1];
        right = box[0] + box[2];
        bottom = box[1] + box[3];
        first = false;
        continue;
      }
      left = left < box[0] ? left : box[0];
      top = top < box[1] ? top : box[1];
      right = right > box[0] + box[2] ? right : box[0] + box[2];
      bottom = bottom > box[1] + box[3] ? bottom : box[1] + box[3];
    }
    return [left, top, right - left, bottom - top];
  }

  static Iterable<_Candidate> _itemsIn(List<Object> nodes) sync* {
    for (var node in nodes) {
      if (node is _Candidate) {
        yield node;
      } else if (node is _Region) {
        yield* _itemsIn(node.children);
      }
    }
  }

  static _Region _thin(_Region region, int minItems) {
    var children = <Object>[];
    for (var child in region.children) {
      if (child is! _Region) {
        children.add(child);
        continue;
      }
      var thinned = _thin(child, minItems);
      // A scrollable survives whatever it holds. Measured: at a threshold of
      // three, the file list's own `ListView` vanished because only two rows
      // were on screen — the single most useful region there.
      if (!thinned.scrolls && thinned.itemCount < minItems) {
        children.addAll(thinned.children);
      } else {
        children.add(thinned);
      }
    }
    // The box a region was built with, not one recomputed from what survived:
    // thinning splices a grouping away and keeps everything it held, so the
    // area covered has not changed.
    return _Region(region.node, children, box: region.box);
  }
}

/// A candidate item, while its words are still being worked out.
class _Candidate {
  _Candidate({
    required this.node,
    required this.role,
    required this.box,
    required this.text,
  });

  final InspectNode node;
  final String role;
  final List<int> box;
  final String? text;
  final List<String> swallowed = [];

  /// Controls found inside this one, filled in by the prune.
  final List<_Candidate> nested = [];

  /// Its place in reading order, assigned once the roll-up has settled.
  int n = 0;

  /// The word order, and the order is load-bearing — see [Screen.of].
  String? get words {
    if (node.label case var label? when label.isNotEmpty) return label;
    if (text != null) return text;
    if (swallowed.isNotEmpty) return swallowed.join(' · ');
    var tooltip = node.properties['tooltip'];
    if (tooltip == null) return null;
    return tooltip.replaceAll('"', '');
  }

  ScreenItem toItem() => ScreenItem(
    n: n,
    role: role,
    words: words,
    box: box,
    selected: node.selected,
    enabled: node.properties['enabled'] != 'false',
    children: [for (var child in nested) child.toItem()],
  );
}

class _Region {
  _Region(this.node, this.children, {required this.box});

  final InspectNode node;
  final List<Object> children;

  /// The node's own rect, or what its children cover when it has none — see
  /// [Screen._prune].
  final List<int> box;

  bool get scrolls => _scrolls(_bare(node.type));

  int get itemCount => children.fold(
    0,
    (sum, child) =>
        sum + (child is _Candidate ? 1 : (child as _Region).itemCount),
  );

  ScreenRegion toRegion() => ScreenRegion(
    label: Screen._label(node),
    box: box,
    scrolls: scrolls,
    children: [
      for (var child in children)
        child is _Region ? child.toRegion() : (child as _Candidate).toItem(),
    ],
  );
}
