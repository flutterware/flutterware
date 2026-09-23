import '../utils/identity_hash.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show Tooltip;

/// Resolves a verb's polymorphic target to a `Finder`.
///
/// A `Finder` passes through, a `String` is visible text, a `Key`, an
/// `IconData` and a `Type` mean the obvious thing, and a [Target] says the
/// things that vocabulary cannot.
///
/// `dynamic` is a deliberate exception to the house no-dynamic preference:
/// `tap('NEXT')` / `tap(Icons.add)` / `tap(Keys.next)` read too well to give
/// up.
Finder finderForTarget(dynamic target) {
  return switch (target) {
    Finder() => target,
    Target() => target.toFinder(),
    String() => find.text(target, findRichText: true),
    Key() => find.byKey(target),
    IconData() => find.byIcon(target),
    Type() => find.byType(target),
    _ => throw ArgumentError(
      'a scenario target is a Finder, a String, a Key, an IconData, a Type '
      'or a Target — got ${target.runtimeType}',
    ),
  };
}

/// Where a verb with a finger puts it down for [target], or null when the
/// target names a widget rather than a coordinate — see [Target.point].
///
/// Only a [Target] can name one, so every other form of target is null here
/// by construction: a `Finder`, a string, a key and a type all say *what*,
/// and where is then the centre of what they found.
Offset? pointOf(dynamic target) => target is Target ? target.point : null;

/// Why a [Target.at] found nothing, when it is off the screen; null for any
/// other target, and for a point on the screen.
String? outsideViewOf(dynamic target) =>
    target is _At ? target.outsideView : null;

/// How a verb's target reads back to a human — quoted when it is the visible
/// text the author wrote, bare otherwise.
///
/// One function because two places need the same spelling: the error a verb
/// throws when its target matches nothing or several, and the target recorded
/// on the captured step. A step that says `tap "Pay"` and an error that says
/// `tap 'Pay'` would be describing the same line two ways.
///
/// A `ValueKey` gets its value rather than its `toString`, which is
/// `[<'shop.getStarted'>]` — three kinds of bracket around the only part
/// anybody wrote. Said as `key 'shop.getStarted'` it stays distinct from the
/// quoted visible-text form, which means something else entirely.
///
/// **A `Finder` is asked what it looks for, never what it found.** Interpolated,
/// a finder is `FinderBase.toString()`, which *evaluates* and returns the
/// widgets it matched — measured at 388 characters for a plain
/// `find.byType(TextField)`, carrying `TextEditingController#b4419`,
/// `_TextFieldState#…` and a `_LocalizationsScope-[GlobalKey#…]`. Every one of
/// those is an identity hash, so the same step recorded in two processes is
/// two different strings, and a comparison aligns steps by this: 38 steps of
/// one real suite reported as retargeted with nothing retargeted about them,
/// each under a title four hundred characters long. `describeMatch` is the
/// finder saying what it *searches for*, which is both the question being
/// asked and the same in every process — 28 characters, and none of them a
/// hash.
String describeTarget(dynamic target) => switch (target) {
  String() => '"$target"',
  ValueKey(:var value) => "key '$value'",
  FinderBase<Object?>() => withoutIdentityHash(
    target.describeMatch(Plurality.one),
  ),
  // Belt and braces for the targets with a `toString` of their own: a step
  // label is compared across processes, so nothing that reaches one may be an
  // address. See [withoutIdentityHash].
  _ => withoutIdentityHash('$target'),
};

/// The target and index inside a `Target.nth`, or null for anything else.
///
/// Internal, and it exists for one message: `Finder.at(i)` is
/// `candidates.elementAt(i)`, so an index past the end throws a `RangeError`
/// out of the evaluate rather than missing the way every other target misses.
/// Writing the refusal that deserves needs the count of what the *inner*
/// target matched, which only the caller of [Target.nth] can ask for and only
/// this can hand it.
({Object target, int index})? nthPartsOf(dynamic target) =>
    target is _Nth ? (target: target.target, index: target.index) : null;

/// The targets the plain vocabulary cannot express: the ones that need a
/// property other than visible text, a scope, or an index.
///
/// ```dart
/// await s.tap(Target.label('Add to cart'));       // semantics label
/// await s.tap(Target.tooltip('Delete'));
/// await s.tap(Target.within(ShopKeys.cart, 'Buy'));
/// await s.tap(Target.nth('Buy', 1));              // the second one
/// ```
///
/// Anything here composes: the scope and the index take targets of their own,
/// so `Target.nth(Target.within(card, 'Buy'), 0)` says what it looks like.
sealed class Target {
  const Target();

  /// By semantics label — the only handle on an icon button that carries no
  /// text. Scenarios turn semantics on by themselves for this, since the
  /// underlying finder throws without them.
  const factory Target.label(String label) = _Label;

  /// By tooltip message.
  const factory Target.tooltip(String message) = _Tooltip;

  /// Visible text *containing* [text], where the plain `String` form matches
  /// the whole string.
  const factory Target.containing(String text) = _Containing;

  /// [child] as found inside [scope] — the scoped lookup that turns "the Buy
  /// button of *this* card" from a `find.descendant` incantation into a line
  /// that reads. [scope] matches itself too, so scoping to a `ListTile` and
  /// asking for that same tile finds it.
  const factory Target.within(Object scope, Object child) = _Within;

  /// The [index]th match of [target], zero-based — for the deliberate
  /// ambiguity a verb would otherwise refuse.
  const factory Target.nth(Object target, int index) = _Nth;

  /// The widget at a point, in the coordinates every box in an observation is
  /// reported in.
  ///
  /// What to reach for when a control has no words. Six or seven of the
  /// forty-odd things on a real screen carry no label, no text and no tooltip
  /// — icon buttons, mostly — and until this there was no way to name one at
  /// all. It is also how a screen item is acted on: the host turns
  /// `{"item": 20}` into the centre of that item's box.
  ///
  /// It resolves through the same ladder as every other target rather than
  /// tapping blind coordinates: the point picks the widget, and being covered,
  /// offscreen or gone is refused exactly as it would be for a text target.
  ///
  /// What the point picks is the widget the pointer would *reach*; where a
  /// verb with a finger puts it down is the point itself — see [point].
  /// Which matters exactly where this form earns its keep, on a surface whose
  /// regions are painted rather than built and therefore share one box: there
  /// the widget is the whole canvas and its centre is a different region
  /// every time.
  ///
  /// The same on both surfaces that speak this vocabulary — a scenario's
  /// verbs and a drive's. `tap(Target.at(x, y))` is `tapAt(Offset(x, y))`,
  /// and `{"at": {"x": …, "y": …}}` is the same press again.
  const factory Target.at(double x, double y) = _At;

  Finder toFinder();

  /// Whether resolving this needs the semantics tree, which a scenario turns
  /// on lazily — it is not free, and it changes what the app builds.
  bool get needsSemantics => false;

  /// The coordinate this target *is*, for the one form that is a coordinate —
  /// [Target.at], and nothing else.
  ///
  /// A verb with a finger asks this before it asks for a centre. The widget a
  /// point resolves to is the thing the pointer would reach, but its centre is
  /// somewhere else entirely when the widget is bigger than the region that
  /// was meant: a full-bleed canvas, a chart, an SVG whose zones are painted
  /// rather than built. There the point *is* the target and the centre is a
  /// guess, so a verb that has one uses it.
  ///
  /// Deliberately not recursive. `Target.nth` and `Target.within` compose
  /// *lookups*, and a lookup that happens to contain a point is still asking
  /// for whatever it found — the point named a scope, not a contact.
  Offset? get point => null;
}

class _At extends Target {
  const _At(this.x, this.y);

  final double x;
  final double y;

  @override
  Finder toFinder() {
    var hit = _hitAt(x, y);
    if (hit == null) return find.byElementPredicate((_) => false);
    // Several widgets can share one render object — a `Padding` under a
    // `Semantics` under a builder all report the same box — so `.first` takes
    // the outermost, which is the one a click means and the one the tree
    // reports at that position.
    return find
        .byElementPredicate((element) => identical(element.renderObject, hit))
        .first;
  }

  /// The innermost render object the framework's own hit test reaches.
  ///
  /// The framework's, not a rectangle comparison: this has to agree with what
  /// a real pointer would touch, so transforms, clips and `IgnorePointer` are
  /// all in play and only the real hit test knows about them.
  ///
  /// Never the view itself. A view adds itself to every hit test, including
  /// one at a point outside it, so taking it would turn "nothing is there"
  /// into a tap on the root that reports success.
  static RenderObject? _hitAt(double x, double y) {
    var view = WidgetsBinding.instance.renderViews.firstOrNull;
    if (view == null) return null;
    var result = BoxHitTestResult();
    view.hitTest(result, position: Offset(x, y));
    for (var entry in result.path) {
      if (entry.target case RenderObject render when render is! RenderView) {
        return render;
      }
    }
    return null;
  }

  /// Why nothing is at this point, when the answer is that it is off the
  /// screen — named with the screen's size, because the likely cause is a
  /// coordinate in physical pixels.
  String? get outsideView {
    var view = WidgetsBinding.instance.renderViews.firstOrNull;
    if (view == null || (Offset.zero & view.size).contains(point)) return null;
    String n(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';
    return '(${n(x)}, ${n(y)}) is outside the screen, which is '
        '${n(view.size.width)} × ${n(view.size.height)} logical pixels — the '
        'space every box in an observation is reported in.';
  }

  @override
  Offset get point => Offset(x, y);

  @override
  String toString() => 'Target.at($x, $y)';
}

class _Label extends Target {
  const _Label(this.label);

  final String label;

  @override
  bool get needsSemantics => true;

  @override
  Finder toFinder() => find.bySemanticsLabel(label);

  @override
  String toString() => 'Target.label("$label")';
}

/// `find.byTooltip`, for the `Tooltip` apps build now.
///
/// flutter_test matches a `RawTooltip` by the message it announces, and
/// `material_ui`'s `Tooltip` builds one — except when it is
/// `excludeFromSemantics` and announces nothing. flutter_test reads that
/// case's message off `package:flutter/material.dart`'s `Tooltip`, a class a
/// `material_ui` app never builds, so this reads it off `material_ui`'s.
Finder findByTooltip(String message) => find.byWidgetPredicate(
  (widget) => switch (widget) {
    RawTooltip(:var semanticsTooltip) => semanticsTooltip == message,
    Tooltip(excludeFromSemantics: true) =>
      (widget.message ?? widget.richMessage?.toPlainText()) == message,
    _ => false,
  },
);

class _Tooltip extends Target {
  const _Tooltip(this.message);

  final String message;

  @override
  Finder toFinder() => findByTooltip(message);

  @override
  String toString() => 'Target.tooltip("$message")';
}

class _Containing extends Target {
  const _Containing(this.text);

  final String text;

  @override
  Finder toFinder() => find.textContaining(text, findRichText: true);

  @override
  String toString() => 'Target.containing("$text")';
}

class _Within extends Target {
  const _Within(this.scope, this.child);

  final Object scope;
  final Object child;

  @override
  bool get needsSemantics =>
      (scope is Target && (scope as Target).needsSemantics) ||
      (child is Target && (child as Target).needsSemantics);

  @override
  Finder toFinder() => find.descendant(
    of: finderForTarget(scope),
    matching: finderForTarget(child),
    matchRoot: true,
  );

  @override
  String toString() =>
      'Target.within(${describeTarget(scope)}, ${describeTarget(child)})';
}

class _Nth extends Target {
  const _Nth(this.target, this.index);

  final Object target;
  final int index;

  @override
  bool get needsSemantics =>
      target is Target && (target as Target).needsSemantics;

  @override
  Finder toFinder() => finderForTarget(target).at(index);

  @override
  String toString() => 'Target.nth(${describeTarget(target)}, $index)';
}
