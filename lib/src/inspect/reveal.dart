import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'guest_inspect.dart';

/// What bringing one node on screen did — the half of `--node` that runs
/// before the picture is taken.
class Reveal {
  const Reveal({this.id, this.scrolled = 0, this.refused});

  /// The node, as the tree *after* the scroll numbers it. Null when nothing
  /// was brought anywhere: the selector named nothing, or several places, and
  /// the crop's own refusal says which.
  ///
  /// Reported rather than left to be resolved again, because an id is a
  /// position. A lazy list that scrolled has renumbered its rows, so the id a
  /// caller passed names another row by now.
  final String? id;

  /// How far the lists moved, in logical pixels, summed over all of them.
  /// Zero when the node was already on screen.
  final double scrolled;

  /// Why a walk stopped without a node, worded for the caller.
  final String? refused;

  Map<String, Object?> toJson() => {
    'id': ?id,
    'scrolled': scrolled,
    'refused': ?refused,
  };
}

/// Scrolls whatever has to scroll for the one place [selector] names to be
/// wholly on screen, and says which node it is afterwards.
///
/// **Minimal, not aligned.** `RenderObject.showOnScreen` moves each list only
/// as far as it takes, through every nested viewport, so a node already on
/// screen moves nothing — and the picture of a node that fits is the picture
/// it always was.
///
/// **Walked when not built yet.** A lazy list builds its rows a viewport or so
/// ahead, so a row forty down is not in the tree to be named. Each list in
/// the demo is stepped a viewport at a time, outermost first, until the name
/// resolves: a whole viewport, because every row between two steps was built
/// by one of them. A list that never produced it is put back. An id is never
/// walked for — it is a position in the tree at rest, and in a scrolled list
/// the same position is another row.
///
/// [pump] lays out after each step. [settle] runs once, after anything moved,
/// to land what the rows that scrolled in asked for before the node's place
/// is read.
Future<Reveal> revealNode(
  GuestInspector inspector,
  String selector, {
  required Future<void> Function() pump,
  Future<void> Function()? settle,
  int maxSteps = 50,
}) async {
  var lists = _listsUnder(inspector.rootOf());
  var rest = {for (var list in lists) list: list.position.pixels};

  var read = inspector.readElements();
  var places = read.tree.places(selector);
  Element? target;
  if (places.length == 1) {
    target = read.elements[places.single.id];
  } else if (places.isEmpty && !_id.hasMatch(selector)) {
    walk:
    for (var list in lists) {
      if (!list.mounted) continue;
      var position = list.position;
      var start = position.pixels;
      for (
        var step = 0;
        step < maxSteps && position.pixels < position.maxScrollExtent;
        step++
      ) {
        position.jumpTo(
          math.min(
            position.pixels + position.viewportDimension,
            position.maxScrollExtent,
          ),
        );
        await pump();
        read = inspector.readElements();
        places = read.tree.places(selector);
        if (places.length == 1) {
          target = read.elements[places.single.id];
          break walk;
        }
        if (places.length > 1) {
          await _putBack(rest, pump);
          var named = places
              .take(8)
              .map((node) => node.description ?? node.label ?? node.type)
              .join(', ');
          return Reveal(
            refused:
                '${places.length} widgets side by side match "$selector" '
                'further down the list: $named'
                '${places.length > 8 ? ', …' : ''}. Their ids would name '
                'other rows at rest — a lazy list renumbers its rows as it '
                'scrolls — so narrow the text instead.',
          );
        }
      }
      if (list.mounted) {
        list.position.jumpTo(start);
        await pump();
      }
    }
  }
  if (target == null) return const Reveal();

  target.renderObject?.showOnScreen();
  await pump();
  if (settle != null && _moved(rest) > 0) {
    await settle();
    // What landed may have resized the rows above it, so once more — still
    // minimal, so a node that stayed put is not moved again.
    if (target.mounted) {
      target.renderObject?.showOnScreen();
      await pump();
    }
  }

  String? id;
  for (var MapEntry(:key, :value)
      in inspector.readElements().elements.entries) {
    if (value == target) {
      id = key;
      break;
    }
  }
  return Reveal(id: id, scrolled: _moved(rest));
}

/// A tree id: positions, `0/3/1`. No widget is called that.
final _id = RegExp(r'^\d+(/\d+)*$');

/// Every list under [root] that can say where it is, outermost first.
List<ScrollableState> _listsUnder(Element? root) {
  var lists = <ScrollableState>[];
  void visit(Element element) {
    if (element case StatefulElement(state: ScrollableState state)) {
      var position = state.position;
      if (position.hasPixels &&
          position.hasContentDimensions &&
          position.hasViewportDimension) {
        lists.add(state);
      }
    }
    element.visitChildren(visit);
  }

  if (root != null) visit(root);
  return lists;
}

double _moved(Map<ScrollableState, double> rest) {
  var moved = 0.0;
  for (var MapEntry(key: list, value: pixels) in rest.entries) {
    if (list.mounted) moved += (list.position.pixels - pixels).abs();
  }
  return moved;
}

Future<void> _putBack(
  Map<ScrollableState, double> rest,
  Future<void> Function() pump,
) async {
  for (var MapEntry(key: list, value: pixels) in rest.entries) {
    if (list.mounted) list.position.jumpTo(pixels);
  }
  await pump();
}
