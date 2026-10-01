import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// What growing the screen to its content did — the half of `--full` that
/// runs before the picture is taken.
class Grown {
  const Grown({required this.from, required this.to, this.truncated = false});

  /// The screen's height before and after, in logical pixels. Equal when
  /// nothing on it scrolls.
  final double from;
  final double to;

  /// Whether a list still had more to show when the screen reached its cap —
  /// a list with no end, or one longer than a picture may be.
  final bool truncated;

  Map<String, Object?> toJson() => {
    'from': from,
    'to': to,
    if (truncated) 'truncated': true,
  };
}

/// Makes the screen as tall as what its lists hold, so one picture shows all
/// of it — a browser's full-page screenshot, with the same bargain.
///
/// **Grown, not stitched.** The screen is made taller and laid out again,
/// which gives one layout and one consistent picture: nothing pinned repeats,
/// nothing at a seam is drawn twice. The price is that a layout reading the
/// screen's height reads the grown one — a hero sized to 40% of the screen,
/// a `SliverFillRemaining` — and that what is pinned to the bottom of the
/// screen, a navigation bar or a floating button, is drawn once, at the
/// bottom of the whole thing.
///
/// Each round grows the screen by the most any list still has to scroll, and
/// three things stop it running away:
///
/// * **A list the screen does not size** — a list in a box of its own height
///   — is left scrolled as it was. It is found by growing and watching: a
///   list whose viewport did not get taller is taken out, and the growth it
///   asked for is undone.
/// * **A list with no end** grows the screen to [maxHeight] and no further,
///   and the answer says it was cut short.
/// * **Rows a lazy list only estimated** can overshoot, since the list
///   guesses the length of rows it has not built. Once everything fits, the
///   screen is shortened by whatever the lists left empty below their last
///   row.
///
/// Only lists on stage are grown: a route a step pushed over another leaves
/// the one underneath mounted, with its tickers off, and growing the screen
/// for a list nobody can see would photograph the page on top with a blank
/// below it.
///
/// [resize] stages a new height and lays it out; [settle] lands what the
/// rows that came on screen asked for.
Future<Grown> growToContent(
  Element? Function() rootOf, {
  required double height,
  required Future<void> Function(double height) resize,
  required Future<void> Function() settle,
  required double maxHeight,
  int maxRounds = 10,
}) async {
  var from = height;
  var fixed = <ScrollableState>{};
  var grown = <ScrollableState>{};
  var truncated = false;

  for (var round = 0; round < maxRounds; round++) {
    var rests = {
      for (var list in _listsOnStage(rootOf()))
        if (!fixed.contains(list) && _rest(list) > _tolerance)
          list: _rest(list),
    };
    if (rests.isEmpty) break;
    if (height >= maxHeight - _tolerance) {
      truncated = true;
      break;
    }
    var before = {
      for (var list in rests.keys) list: list.position.viewportDimension,
    };
    var previous = height;
    height = math.min(height + rests.values.reduce(math.max), maxHeight);
    await resize(height);
    await settle();

    var stuck = [
      for (var list in rests.keys)
        if (list.mounted &&
            list.position.viewportDimension <= before[list]! + _tolerance)
          list,
    ];
    grown.addAll(rests.keys.where((list) => !stuck.contains(list)));
    if (stuck.isNotEmpty) {
      // The growth was sized by all of them, so it is undone for all of
      // them, and the ones that did grow ask again without the others.
      fixed.addAll(stuck);
      height = previous;
      await resize(height);
      await settle();
    }
  }

  // The lists fit; take back what they left empty below their last row.
  var slack = [
    for (var list in grown)
      if (list.mounted) _slack(list) ?? 0,
  ].fold<double?>(null, (least, s) => least == null ? s : math.min(least, s));
  if (slack != null && slack > _tolerance && height > from) {
    var trimmed = math.max(from, height - slack);
    await resize(trimmed);
    await settle();
    if (grown.any((list) => list.mounted && _rest(list) > _tolerance)) {
      // Something that fit no longer does — a layout that sizes a row by
      // the screen. The taller screen was the right one.
      await resize(height);
      await settle();
    } else {
      height = trimmed;
    }
  }

  // Asked of what is on stage now, not of the rounds: a list that went on
  // growing past the cap is still showing that it has more.
  if (!truncated && height >= maxHeight - _tolerance) {
    truncated = _listsOnStage(rootOf())
        .any((list) => !fixed.contains(list) && _rest(list) > _tolerance);
  }
  return Grown(from: from, to: height, truncated: truncated);
}

/// Half a logical pixel: a layout that rounds is not a list with more to
/// show.
const _tolerance = 0.5;

/// How much further [list] scrolls than its viewport shows. Infinite for a
/// list whose builder never ends.
double _rest(ScrollableState list) {
  var position = list.position;
  if (!position.hasContentDimensions) return 0;
  return position.maxScrollExtent - position.minScrollExtent;
}

/// How much of [list]'s viewport lies below its last row, or null for a
/// scrollable that is not built from slivers — a `SingleChildScrollView`
/// knows its child's height exactly, so it never overshoots.
double? _slack(ScrollableState list) {
  RenderViewportBase? viewport;
  void find(Element element) {
    if (viewport != null) return;
    if (element.renderObject case RenderViewportBase found) {
      viewport = found;
      return;
    }
    element.visitChildren(find);
  }

  (list.context as Element).visitChildren(find);
  var found = viewport;
  if (found == null || !found.hasSize) return null;
  var extent = 0.0;
  for (
    var sliver = found.firstChild;
    sliver != null;
    sliver = found.childAfter(sliver)
  ) {
    extent += sliver.geometry?.scrollExtent ?? 0;
  }
  return list.position.viewportDimension - extent;
}

/// Every vertical list under [root] that is laid out and on stage.
List<ScrollableState> _listsOnStage(Element? root) {
  var lists = <ScrollableState>[];
  void visit(Element element) {
    if (element case StatefulElement(state: ScrollableState state)) {
      var position = state.position;
      if (axisDirectionToAxis(state.axisDirection) == Axis.vertical &&
          position.hasPixels &&
          position.hasContentDimensions &&
          position.hasViewportDimension &&
          // Without a dependency: this runs outside any build, and a lookup
          // that subscribed would rebuild the list when a route moved.
          TickerMode.getValuesNotifier(element).value.enabled) {
        lists.add(state);
      }
    }
    element.visitChildren(visit);
  }

  if (root != null) visit(root);
  return lists;
}
