import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart' show InputDecorator;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../scenarios/target.dart';
import 'human_actions.dart' show nameHit;

/// The four ways the actionability ladder refuses a target.
///
/// The kind matters to a live driver: on a screen mid-transition every one of
/// these can be transient — a route still animating holds an `IgnorePointer`
/// up (`covered`), and both pages are in the tree at once (`multiple`) — so
/// the drive verbs retry all of them until their deadline, where a scenario
/// under fake time fails immediately because its screen is already settled.
enum TargetFailure { notFound, multiple, covered, offscreen }

/// A refusal from [TargetResolver] — the message is the whole story, written
/// to say what to do rather than dump matching render objects.
class TargetError implements Exception {
  TargetError(this.failure, this.message);

  final TargetFailure failure;
  final String message;

  @override
  String toString() => message;
}

/// The wording of a refusal, flavored per host.
///
/// The logic of the ladder is shared; the sentences are not quite: a scenario
/// speaks of `s.tap` and offers `s.tester` as the escape hatch, a live driver
/// has no receiver prefix and no raw tester to offer. Everything else is
/// deliberately identical, so a failure reads the same to a scenario author
/// and to an agent driving a live app.
class TargetMessages {
  const TargetMessages({
    this.prefix = '',
    this.coveredEscapeHatch = '',
    this.blankScreenHint = '',
    this.narrowHint =
        'Narrow it: give the widget a Key and use that, or pass a Finder — '
        '`finder.first`, `find.descendant(of: …, matching: …)`.',
  });

  /// Goes in front of verb names in messages — `'s.'` for scenarios, where
  /// the reader will retype the verb on a receiver called `s`.
  final String prefix;

  /// Appended to the covered refusal — scenarios offer `s.tester` here.
  final String coveredEscapeHatch;

  /// Replaces the lazy-list guess when the screen carries no text at all.
  ///
  /// The lazy-list sentence is the right guess for a mature suite and the
  /// wrong one for a first run, where nothing has rendered and no amount of
  /// scrolling will help. Flavored per host because the cause is: a scenario
  /// under fake time is usually waiting on something FakeAsync will not
  /// complete, while a live app is usually just still drawing.
  final String blankScreenHint;

  /// The nothing-matched refusal.
  ///
  /// [hint] is what the resolver worked out about *this* miss — a rendered
  /// string that differs from the wanted one by an invisible character, or
  /// a semantics label carrying the words. It replaces the guess rather than
  /// joining it: told the exact string is on screen, a reader does not also
  /// need to be told to scroll. [prelude] goes in front of either, for the
  /// part of a composed target that failed before the miss itself matters.
  ///
  /// [scrolls] is whether the screen holds a `Scrollable` at all. The
  /// lazy-list guess was once unconditional, and "nothing matches" has two
  /// very different causes: on a real suite it sent a reader hunting scroll
  /// positions when the list the target should have been in was *empty* — the
  /// screenshot said so, the message pointed away from it. So the guess only
  /// offers `scrollTo` where scrolling exists, and names the empty-list cause
  /// beside it either way.
  String notFound(
    String verb,
    String described,
    String? screen, {
    bool blank = false,
    bool scrolls = true,
    String? hint,
    String prelude = '',
  }) {
    var guess = blank && blankScreenHint.isNotEmpty
        ? blankScreenHint
        : scrolls
        ? 'Either a widget further down a lazy list is not built yet — '
              '`${prefix}scrollTo` walks to it — or the list that would hold '
              'it is empty; the visible text says which.'
        : 'Nothing on this screen scrolls, so it is not hiding further down '
              '— it was never built. The visible text is the whole screen.';
    return 'nothing matches $described, which `$prefix$verb` needs. '
        '$prelude${hint ?? guess}'
        '${screen == null ? '' : '\nVisible text: $screen'}';
  }

  /// An `nth` index past the end of what its target matched.
  ///
  /// Both halves are named because both are wrong in different calls, and the
  /// exception underneath tells them apart badly: `elementAt` says "no indices
  /// are valid" when the target matched *zero* widgets, which never mentions
  /// the count that is the actual problem, and reads like a complaint about
  /// the index when the index is the one part that was fine.
  String outOfRange(String inner, int count, int index) =>
      '$inner matches $count widget${count == 1 ? '' : 's'}, so `nth` index '
      '$index is out of range — '
      '${count == 1 ? 'the only index is 0' : 'valid indices are 0–${count - 1}'}.';

  /// An `nth` over a target that matches nothing at all.
  ///
  /// Said first and on its own: the index is not what needs fixing, so the
  /// reader should stop looking at it and read the miss underneath.
  String nthOverNothing(String inner) =>
      '`nth` has nothing to index — $inner matches nothing, so the index is '
      'not the problem. ';

  /// A rendered string that is *nearly* the one asked for.
  ///
  /// The refusal is the one position that can notice: it holds the wanted
  /// string and the candidates, and neither string shows the difference to
  /// anyone staring at it — a narrow no-break space before AM/PM, a curly
  /// apostrophe, a non-breaking hyphen. So the character is named rather than
  /// printed, and the offered target is the prefix that is known to match.
  String nearMiss({
    required String rendered,
    required String common,
    required String? yours,
    required String theirs,
  }) {
    var at = yours == null
        ? 'yours ends and the rendered one continues with $theirs'
        : 'yours has $yours and the rendered one has $theirs';
    return 'No exact match, but "$rendered" is on screen and differs from '
        'yours at character ${common.length}: $at. Target it with '
        '`{"containing": ${jsonEncode(common)}}`, or copy the rendered string.';
  }

  /// A miss on rendered text that another property would have hit.
  ///
  /// `screen` is the thing you read to decide what to act on, and its `w`
  /// is whatever carries the control's words: the semantics label first — a
  /// `Slider.label`, an icon button's `Semantics` — and the tooltip when
  /// nothing else does. A bare target is rendered text only, so a reader
  /// copying a `w` verbatim lands in a refusal that reads like the control is
  /// unreachable, which is the one thing it is not.
  ///
  /// [noun] is what the property is called in prose, [form] the key that
  /// targets it — "semantics label" and `label`, "tooltip" and `tooltip`.
  String propertyMiss(
    int count, {
    required String noun,
    required String form,
  }) =>
      'No *rendered* text matches, but $count $noun${count == 1 ? '' : 's'} '
      'do${count == 1 ? 'es' : ''} — target it with `{"$form": …}`. A bare '
      "target matches rendered text only, while `screen` reports a control's "
      '`w` from its semantics label or its tooltip wherever it has one.';

  /// How to get from many matches to one, flavored per host.
  ///
  /// A scenario author edits the app and retypes the call, so a `Key` and a
  /// `Finder` are the right answers. An agent driving a live app can do
  /// neither — it cannot add a key to a running app and has no `Finder` to
  /// pass — so the default advice was a refusal that told it to do the one
  /// thing it could not do. It has `nth` and `item`; the message says so.
  final String narrowHint;

  /// The refusal that has to be usable in one step.
  ///
  /// It names the matches. A caller told only that two things matched has
  /// to go and look before it can choose, and the look is another round trip
  /// against a screen that may have moved. [where] is one line per match, in
  /// the order `nth` indexes them, so the number in front of a box is the
  /// `index` that picks it.
  String multiple(
    int count,
    String verb,
    String described, [
    List<String> where = const [],
  ]) =>
      '$count widgets match $described, and `$prefix$verb` needs one'
      '${where.isEmpty ? '. ' : ':\n${where.join('\n')}\n'}'
      '$narrowHint';

  /// [landsOn] names what the pointer actually reaches, when the hit test
  /// could name it. It comes from the hit path the reachability check already
  /// ran — a fact, not a guess. Without it the sentence falls back to the two
  /// usual causes, both of which can be wrong at once: an `OverflowBox` that
  /// pushes a target's centre over a neighbour covers nothing and absorbs
  /// nothing.
  String covered(String verb, String described, {String? landsOn}) =>
      '$described is on screen, but `$prefix$verb` at its center would not '
      'reach it — '
      '${landsOn == null ? 'another widget covers it, or an IgnorePointer/'
                'AbsorbPointer swallows the pointer' : 'the pointer there lands on $landsOn instead'}'
      '.$coveredEscapeHatch';

  /// The covered refusal for the one covering that is not a mistake: a text
  /// field's own decoration.
  ///
  /// A field's `labelText` is a visible string, so a bare target matches
  /// it — and matches the label `Text`, the one widget in that field nobody
  /// can act on: the decoration sits under an `IgnorePointer`, so the pointer
  /// at the label's centre goes to the field. The generic covered sentence is
  /// true and useless there, because the thing "covering" the label is the
  /// field the caller was aiming at all along.
  ///
  /// [label] is `{"label": …}` spelled out, and it arrives **only when the
  /// resolver has just checked that it resolves** — a refusal that hands back
  /// an address it has not tried costs the reader the round trip it was
  /// written to save. Null leaves the point, which the ladder can always
  /// vouch for.
  String decorationLabel(
    String verb,
    String described, {
    required String? label,
    required Offset center,
  }) =>
      "$described belongs to a text field's decoration — its label, its hint, "
      'a prefix — and `$prefix$verb` at its centre lands on the field rather '
      'than on it. Act on the field: '
      '`{"at": {"x": ${center.dx.round()}, "y": ${center.dy.round()}}}`, its '
      'centre'
      '${label == null ? '' : ', or `{"label": ${jsonEncode(label)}}`'}.';

  String offscreen(String described, Offset center) =>
      '$described sits off screen at $center and nothing scrolls it '
      'into view.';

  String nothingScrolls(Object? within) => within == null
      ? 'nothing on screen scrolls, so `${prefix}scrollTo` has nothing to '
            'walk.'
      : 'nothing under $within scrolls, so `${prefix}scrollTo` has nothing '
            'to walk.';

  String scrollExhausted(int maxScrolls, double step, String described) =>
      'scrolled $maxScrolls times by $step without reaching $described. '
      'Wrong direction (try a negative step), wrong scrollable (name one '
      'with `within:`), or it is not in this list at all.';
}

/// Resolves a verb's target and insists it names exactly one widget the
/// pointer can actually reach — the ladder every pointer verb climbs, over
/// any [WidgetController]: a `WidgetTester` under fake time or a live
/// controller over the real binding.
///
/// Found but unreachable usually means "built but below the fold" — a
/// `SingleChildScrollView`, a list child inside cache extent — so the ladder
/// first scrolls it into view, as the user it stands in for would. What
/// scrolling cannot fix is refused loudly, with the kind on the error so a
/// live caller can decide what is worth retrying.
class TargetResolver {
  TargetResolver(
    this.controller, {
    this.messages = const TargetMessages(),
    this._pump,
    this.ensureSemantics,
    this.describeScreen,
    this.namedCovering,
  });

  final WidgetController controller;
  final TargetMessages messages;

  /// One pump after `ensureVisible`, so the scroll it triggered is applied
  /// before the recheck. Injected because pumping is the one thing the two
  /// bindings do differently — a live pump must survive a hidden window.
  final Future<void> Function()? _pump;

  /// Called before resolving a [Target] that needs the semantics tree, which
  /// is not free and is turned on lazily by the host.
  final Future<void> Function()? ensureSemantics;

  /// One line describing what is on screen, for the nothing-matches message —
  /// the first thing whoever wrote the target needs to see.
  final String Function()? describeScreen;

  /// A refusal for a covering the host can *name*, outranking the generic
  /// covered sentence. Given the target's centre, the verb and how the target
  /// reads; null means this is not that covering.
  ///
  /// The engine deliberately knows nothing about what might be doing the
  /// covering. A scenario's software keyboard is the first case — it absorbs
  /// the pointer exactly as a real one does, so the generic sentence would be
  /// true and would send the reader looking for an overlay that is not in
  /// their code.
  final String? Function(Offset center, String verb, String described)?
  namedCovering;

  Future<Finder> resolve(dynamic target, String verb) async {
    if (target is Target && target.needsSemantics) {
      await ensureSemantics?.call();
    }
    var finder = finderForTarget(target);
    var described = describeTarget(target);
    var count = _countOf(finder);
    if (count == null) throw _indexRefusal(target, described, verb);
    if (count == 0) {
      throw TargetError(
        TargetFailure.notFound,
        messages.notFound(
          verb,
          described,
          describeScreen?.call(),
          blank: _screenIsBlank,
          scrolls: _screenScrolls,
          hint: _diagnose(target),
        ),
      );
    }
    if (count > 1) {
      throw TargetError(
        TargetFailure.multiple,
        messages.multiple(count, verb, described, _whereEachIs(finder)),
      );
    }
    await _ensureReachable(finder, described, verb, pointOf(target));
    return finder;
  }

  /// How many widgets [finder] matches, or null when it indexed past its end.
  ///
  /// `Finder.at(i)` is `candidates.elementAt(i)`, so an out-of-range `nth` is
  /// a `RangeError` thrown out of the evaluate rather than a miss. Caught here
  /// and turned into a [TargetError] for two reasons: the raw error is the one
  /// refusal in this tool that does not say what to do next, and — being no
  /// [TargetError] — it also escaped the retry ladder every other refusal
  /// gets, so an `nth` on a screen mid-transition failed hard where a plain
  /// text target would have been pumped through.
  static int? _countOf(Finder finder) {
    try {
      return finder.evaluate().length;
    } on RangeError {
      return null;
    }
  }

  /// The refusal for an out-of-range index, with the count in it.
  ///
  /// Targets compose, so `nth(nth(…))` runs out at whichever level ran out
  /// first and the sentence has to be about *that* one; the walk descends to
  /// the innermost `nth` whose own target still evaluates.
  TargetError _indexRefusal(dynamic target, String described, String verb) {
    dynamic offender = target;
    while (true) {
      var parts = nthPartsOf(offender);
      if (parts == null) break;
      var inner = parts.target;
      var count = _countOf(finderForTarget(inner));
      // The inner target range-errored too, so the level that actually ran
      // out is further in; this one never got to index anything.
      if (count == null) {
        offender = inner;
        continue;
      }
      var innerDescribed = describeTarget(inner);
      // An index over a target that matched nothing is not an index problem
      // at all, and `elementAt`'s "no indices are valid" never says so.
      if (count == 0) {
        return TargetError(
          TargetFailure.notFound,
          messages.notFound(
            verb,
            describeTarget(offender),
            describeScreen?.call(),
            blank: _screenIsBlank,
            scrolls: _screenScrolls,
            hint: _diagnose(inner),
            prelude: messages.nthOverNothing(innerDescribed),
          ),
        );
      }
      return TargetError(
        TargetFailure.notFound,
        messages.outOfRange(innerDescribed, count, parts.index),
      );
    }
    // No `nth` anywhere in it: something else indexed past its end, and a
    // guess about what would be worse than the generic miss.
    return TargetError(
      TargetFailure.notFound,
      messages.notFound(
        verb,
        described,
        describeScreen?.call(),
        blank: _screenIsBlank,
        scrolls: _screenScrolls,
      ),
    );
  }

  /// What is actually wrong with a target that matched nothing, when the
  /// screen can be made to say — see [TargetMessages.nearMiss] and
  /// [TargetMessages.propertyMiss]. Null when it cannot, and then the refusal
  /// keeps its guess.
  String? _diagnose(dynamic target) {
    if (outsideViewOf(target) case var outside?) return outside;
    if (target is! String || target.isEmpty) return null;
    return _nearMiss(target) ?? _propertyMiss(target);
  }

  /// The same words, carried by a property a bare target does not read.
  ///
  /// Tooltip before semantics because it is the cheaper question and, on a
  /// live app, the likelier one: a tooltip is always there to be asked about,
  /// where the semantics tree is off until something holds a handle.
  String? _propertyMiss(String wanted) {
    var tooltips = find.byTooltip(wanted).evaluate().length;
    if (tooltips > 0) {
      return messages.propertyMiss(tooltips, noun: 'tooltip', form: 'tooltip');
    }
    var labels = _semanticsMatches(wanted);
    if (labels != null) {
      return messages.propertyMiss(
        labels,
        noun: 'semantics label',
        form: 'label',
      );
    }
    return null;
  }

  /// The rendered string sharing the longest prefix with [wanted].
  ///
  /// A prefix rather than a substring because that is what actually catches
  /// the case: the wanted and rendered strings agree up to the character
  /// nobody can see and diverge there, so `textContaining(wanted)` — the
  /// obvious probe — misses for the same reason `find.text` did.
  String? _nearMiss(String wanted) {
    String? best;
    var bestPrefix = 0;
    for (var candidate in visibleTextsOf(controller)) {
      if (candidate.isEmpty || candidate == wanted) continue;
      var shared = _commonPrefix(wanted, candidate);
      if (shared > bestPrefix) {
        bestPrefix = shared;
        best = candidate;
      }
    }
    // Half the string and at least three characters: two words that happen to
    // start with the same letter are a coincidence, not a near miss.
    if (best == null || bestPrefix < 3 || bestPrefix * 2 < wanted.length) {
      return null;
    }
    var yoursRuns = bestPrefix < wanted.length;
    var renderedRuns = bestPrefix < best.length;
    // **Where the rendered string simply stops, this is not a near miss.**
    // `"Item 40"` against a list showing `"Item 4"` shares six characters and
    // means nothing by it: the wanted item is further down the lazy list, and
    // saying "differs at character 6" there suppresses the one hint that was
    // right. Kept only when what yours continues with is itself invisible —
    // the typed-a-trailing-space version of the same bug.
    if (!renderedRuns &&
        !(yoursRuns &&
            _confusableNames.containsKey(wanted.codeUnitAt(bestPrefix)))) {
      return null;
    }
    return messages.nearMiss(
      rendered: best,
      common: wanted.substring(0, bestPrefix),
      yours: yoursRuns ? _nameChar(wanted, bestPrefix) : null,
      theirs: renderedRuns
          ? _nameChar(best, bestPrefix)
          : 'nothing — it ends there',
    );
  }

  /// Matches the semantics tree does have, when it is already on.
  ///
  /// Never turns semantics on to answer. It is not free, it changes what
  /// the app builds, and an error path is the last place to do that quietly —
  /// and it would buy nothing: a label that never reached a `screen` reply is
  /// not the label anybody copied.
  int? _semanticsMatches(String wanted) {
    if (!SemanticsBinding.instance.semanticsEnabled) return null;
    var count = find.bySemanticsLabel(wanted).evaluate().length;
    return count == 0 ? null : count;
  }

  /// Code units, not runes: the index is only ever handed back inside a
  /// substring of one of the two strings, so a surrogate pair can be split
  /// only where the strings already differ inside one — and there both halves
  /// are named by codepoint anyway.
  static int _commonPrefix(String a, String b) {
    var limit = math.min(a.length, b.length);
    var i = 0;
    while (i < limit && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  /// The character at [index], said in a way that survives being invisible.
  ///
  /// Printing it is what fails: the whole class of bug here is characters that
  /// look like the one you typed or like nothing at all, so the codepoint
  /// leads and the glyph follows only when there is one worth showing.
  static String _nameChar(String text, int index) {
    var code = text.codeUnitAt(index);
    var hex = code.toRadixString(16).toUpperCase().padLeft(4, '0');
    if (_confusableNames[code] case var name?) return 'U+$hex $name';
    var printable = code > 0x20 && code < 0x7F;
    return printable ? 'U+$hex "${text[index]}"' : 'U+$hex';
  }

  /// How many matches a refusal lists before it stops.
  ///
  /// A target matching thirty things is a problem with the target rather than
  /// with the thirty, and the count in front of the list already reports it.
  static const listedMatches = 10;

  /// Where each match is, numbered as `nth` indexes them.
  ///
  /// The box rather than the widget: a text target matches the `RichText`
  /// under every `Text`, so the types are identical and say nothing, where
  /// the rects are what tell an app bar title from the button below it — and
  /// a centre computed off one is itself a target, `{"at": {"x": …, "y": …}}`.
  List<String> _whereEachIs(Finder finder) {
    var elements = finder.evaluate().toList();
    return [
      for (var (index, element) in elements.take(listedMatches).indexed)
        '  $index ${_where(element)}',
      if (elements.length > listedMatches)
        '  … and ${elements.length - listedMatches} more',
    ];
  }

  static String _where(Element element) {
    var render = element.renderObject;
    if (render is! RenderBox || !render.hasSize) return 'nothing laid out';
    var box = render.localToGlobal(Offset.zero) & render.size;
    return 'at ${box.left.round()},${box.top.round()} '
        '${box.width.round()}×${box.height.round()}';
  }

  /// Whether the screen the target was refused on carries any text.
  ///
  /// Read off the tree rather than off [describeScreen]'s sentence: the
  /// wording is a host's business, and a message that changes meaning would
  /// silently change which hint a reader gets.
  bool get _screenIsBlank =>
      !visibleTextsOf(controller).any((text) => text.isNotEmpty);

  /// Whether the refused screen can scroll at all — what decides if the
  /// refusal may honestly suggest `scrollTo`.
  bool get _screenScrolls =>
      controller.widgetList(find.byType(Scrollable)).isNotEmpty;

  Future<void> _ensureReachable(
    Finder finder,
    String described,
    String verb,
    Offset? point,
  ) async {
    if (_reaches(finder, point)) return;
    // On a target with no scrollable ancestor `Scrollable.ensureVisible` is a
    // no-op, so the recheck decides — no case to distinguish here.
    await controller.ensureVisible(finder);
    await (_pump?.call() ?? controller.pump());
    // That pump can rebuild the tree from under the finder — the
    // mid-transition flicker this whole ladder exists to survive. A target
    // that vanished is the refusal the retry loop knows how to pump through,
    // not a bare `StateError` out of `.single` below.
    if (finder.evaluate().length != 1) {
      throw TargetError(
        TargetFailure.notFound,
        messages.notFound(
          verb,
          described,
          describeScreen?.call(),
          blank: _screenIsBlank,
          scrolls: _screenScrolls,
        ),
      );
    }
    if (_reaches(finder, point)) return;
    var render = finder.evaluate().single.renderObject! as RenderBox;
    var center = render.localToGlobal(render.size.center(Offset.zero));
    var view = _viewOf(render);
    var bounds = Offset.zero & (view?.size ?? Size.zero);
    if (bounds.contains(center)) {
      throw TargetError(
        TargetFailure.covered,
        // The named covering first: it is the most specific thing anybody
        // knows about why this failed, and the two below are what to say when
        // nobody knows.
        namedCovering?.call(center, verb, described) ??
            _decorationRefusal(finder, described, verb) ??
            messages.covered(
              verb,
              described,
              landsOn: nameHit(center, viewId: view?.flutterView.viewId),
            ),
      );
    }
    throw TargetError(
      TargetFailure.offscreen,
      messages.offscreen(described, center),
    );
  }

  /// The refusal for a target that landed inside a text field's decoration,
  /// or null when it landed anywhere else — see
  /// [TargetMessages.decorationLabel].
  ///
  /// The walk stops at whichever of `EditableText` and `InputDecorator` it
  /// meets first, and that order is the test: the field's *value* is drawn
  /// inside the editable, everything the decoration draws around it — label,
  /// hint, helper, prefix — is not. Reaching the editable first means the
  /// covering is an ordinary one and gets the ordinary sentence.
  String? _decorationRefusal(Finder finder, String described, String verb) {
    var elements = finder.evaluate().toList();
    if (elements.length != 1) return null;
    Element? decorator;
    elements.single.visitAncestorElements((ancestor) {
      if (ancestor.widget is EditableText) return false;
      if (ancestor.widget is! InputDecorator) return true;
      decorator = ancestor;
      return false;
    });
    var found = decorator;
    if (found == null) return null;
    var render = found.renderObject;
    if (render is! RenderBox || !render.hasSize) return null;
    return messages.decorationLabel(
      verb,
      described,
      label: _labelReaching(found),
      center: render.localToGlobal(render.size.center(Offset.zero)),
    );
  }

  /// The `{"label": …}` that reaches the field [decorator] decorates, or null
  /// when this cannot say that it does.
  ///
  /// Deduced from the decoration, then resolved — never deduced and
  /// offered. The first version of this message read `labelText ?? hintText`
  /// off the decoration and handed it over, which a widget test agreed with
  /// and the live GUI did not: on the studio's own filter field the offered
  /// label found nothing, because a word had just been typed into it and a
  /// hint stops being the field's semantics label somewhere the widget test
  /// did not reproduce. Whatever the rule is, this does not need to know it —
  /// it runs the caller's own lookup and keeps the string only when that
  /// lands on one widget holding this field's editable.
  ///
  /// Null whenever the semantics tree is off, for the reason in
  /// [_semanticsMatches]: turning it on to write an error message changes what
  /// the app builds. The point in the same sentence never needed it.
  String? _labelReaching(Element decorator) {
    if (!SemanticsBinding.instance.semanticsEnabled) return null;
    var decoration = (decorator.widget as InputDecorator).decoration;
    var said = decoration.labelText ?? decoration.hintText;
    if (said == null) return null;
    var matches = find.bySemanticsLabel(said).evaluate().toList();
    if (matches.length != 1) return null;
    // The same search the verb will make: one match, holding one editable —
    // and that editable inside this decorator, so the label being unique on
    // the screen is not mistaken for it belonging to this field.
    var editables = editableWithin(
      find.byElementPredicate((element) => identical(element, matches.single)),
    ).evaluate().toList();
    if (editables.length != 1) return null;
    var inside = false;
    editables.single.visitAncestorElements((ancestor) {
      inside = identical(ancestor, decorator);
      return !inside;
    });
    return inside ? said : null;
  }

  /// The view [render] paints into, walked up the render tree.
  ///
  /// Not `binding.renderViews.single`, which is a `Bad state: Too many
  /// elements` waiting for the first app that opens a second window — and
  /// `.first` in its place would be a guess that silently hit-tests one view
  /// against another's coordinates. The target itself knows which view it is
  /// in; this asks it.
  static RenderView? _viewOf(RenderObject render) {
    for (RenderObject? node = render; node != null; node = node.parent) {
      if (node is RenderView) return node;
    }
    return null;
  }

  /// Whether a pointer event where the verb will put it down would reach the
  /// target — the check `flutter_test`'s `warnIfMissed` makes, as a boolean.
  ///
  /// [point] is where that is, when the target named a coordinate; the
  /// centre of what it resolved to otherwise. Asking about the centre of a
  /// point target would be asking the wrong question and answering it wrong:
  /// a canvas half under a sheet is reachable at every point still showing,
  /// and its centre — the only place the old check looked — is not.
  ///
  /// For a point this is close to true by construction, since the point
  /// resolved *through* a hit test in the first place. Close to, not equal:
  /// the tree can have rebuilt since, and this is the check that notices.
  bool _reaches(Finder finder, Offset? point) {
    var render = finder.evaluate().single.renderObject;
    // No box to aim at: leave it to the underlying verb, whose own errors
    // name the shape problem better than a reachability check can.
    if (render is! RenderBox || !render.hasSize) return true;
    // Nor is an unattached target something a hit test can answer about.
    var view = _viewOf(render);
    if (view == null) return true;
    var at = point ?? render.localToGlobal(render.size.center(Offset.zero));
    // The viewId is passed explicitly: `hitTestOnBinding`'s default comes
    // from the controller's test-typed `view` getter, which throws on a live
    // binding (measured — see 2026-08-11-run-drive-spike-findings.md).
    var result = controller.hitTestOnBinding(
      at,
      viewId: view.flutterView.viewId,
    );
    return result.path.any(
      (entry) => isRenderObjectAncestorOfTarget(render, entry.target),
    );
  }
}

/// The refusal `scrollTo` owes when nothing on screen scrolls, or null when
/// it owes none: a target already on screen has nowhere to be walked to, and
/// a page too short to scroll is the normal case in a flow whose pages vary
/// in length — a consumer suite measured the old unconditional refusal as a
/// guard every walking scenario had to carry.
///
/// The refusal stays for the two real dead ends: [target] matches nothing
/// (and nothing scrolls, so it can never be reached), and it is built but
/// off screen with nothing to walk it into view.
TargetError? refusalWhenNothingScrolls(
  Finder target,
  String described,
  Object? within,
  TargetMessages messages,
) {
  Offset? offCenter;
  for (var element in target.evaluate()) {
    var render = element.renderObject;
    if (render is! RenderBox || !render.hasSize) continue;
    var center = render.localToGlobal(render.size.center(Offset.zero));
    var view = TargetResolver._viewOf(render);
    // Unattached goes to the verb, as [TargetResolver._reaches] leaves it.
    if (view == null || (Offset.zero & view.size).contains(center)) {
      return null;
    }
    offCenter = center;
  }
  return offCenter == null
      ? TargetError(TargetFailure.notFound, messages.nothingScrolls(within))
      : TargetError(
          TargetFailure.offscreen,
          messages.offscreen(described, offCenter),
        );
}

/// The element `scrollTo` should jump to rather than walk toward: [target]'s
/// one match once scrolled-away children are counted, provided it lives under
/// a scrollable [scrollables] matches.
///
/// The walk cannot reach a target the viewport has already scrolled past: a
/// finder skips what `debugVisitOnstageChildren` does not visit, and a child
/// behind the viewport is exactly that, so the drag loop never sees it coming
/// and marches to the far end of the list — measured on a consumer suite as a
/// four-pill filter row that tapped the last pill and could no longer reach
/// the first. The element itself is still in the tree (a short list keeps
/// everything built), and `Scrollable.ensureVisible` reads its own position,
/// so the jump covers both directions and both axes without being told
/// either.
///
/// Null when the walk is the right tool after all: nothing built matches (a
/// lazy list disposes what it scrolled past), several match, or the one match
/// lives somewhere scrolling these scrollables cannot reveal — an inactive
/// route, mostly, which is the other thing `skipOffstage` was hiding and a
/// jump must not silently "reach".
Element? scrolledPastTarget(Finder target, Finder scrollables) {
  var matches = _IncludingScrolledAway(target).evaluate();
  if (matches.length != 1) return null;
  var element = matches.single;
  var roots = scrollables.evaluate().toSet();
  if (roots.isEmpty) return null;
  Element? inside;
  element.visitAncestorElements((ancestor) {
    if (roots.contains(ancestor)) {
      inside = element;
      return false;
    }
    return true;
  });
  return inside;
}

/// The inner finder's matching rules over the whole element tree —
/// `skipOffstage` off, so children the viewport has scrolled past are
/// candidates too.
class _IncludingScrolledAway extends Finder {
  _IncludingScrolledAway(this._inner) : super(skipOffstage: false);

  final Finder _inner;

  @override
  String describeMatch(Plurality plurality) => _inner.describeMatch(plurality);

  // Abstract on `Finder` for legacy reasons; never read, since
  // [describeMatch] above is the one refusals go through.
  @override
  String get description => describeMatch(Plurality.many);

  @override
  Iterable<Element> findInCandidates(Iterable<Element> candidates) =>
      // A compound target (`within:`, whose inner halves evaluate on their
      // own) keeps its onstage view of the tree and simply never matches
      // here, which sends the verb back to the walk — degraded, never wrong.
      _inner.findInCandidates(candidates);
}

/// The `EditableText` a text-entering verb means, given the [finder] its
/// target resolved to.
///
/// A point inside a field resolves *below* the editable, not above it.
/// `Target.at` — which is what `item:` becomes — takes the innermost render
/// object the hit test reached, and inside a `TextField` that is the
/// `RenderEditable` itself. The descendant search alone then comes back
/// empty, because `EditableText` is an *ancestor* of what the point resolved
/// to, and the verb refuses a field the caller can see with "contains 0 text
/// fields", which contradicts what is on their screen.
///
/// So the search runs both ways: down first, which is what a target naming
/// the `TextField`, its key or its semantics label needs, then up to the
/// nearest *enclosing* editable. A point inside a field means that field
/// either way.
///
/// Enclosing, and nothing looser: a point on an icon inside a field's
/// decoration is on the icon, and typing into the field beside it would be a
/// guess. Nothing found leaves the empty descendant finder, so the caller
/// still refuses with the count it would have refused with.
Finder editableWithin(Finder finder) {
  var within = find.descendant(
    of: finder,
    matching: find.byType(EditableText),
    matchRoot: true,
  );
  if (within.evaluate().isNotEmpty) return within;
  var elements = finder.evaluate().toList();
  if (elements.length != 1) return within;
  Element? enclosing;
  elements.single.visitAncestorElements((ancestor) {
    if (ancestor.widget is! EditableText) return true;
    enclosing = ancestor;
    return false;
  });
  var found = enclosing;
  if (found == null) return within;
  return find.byElementPredicate((element) => identical(element, found));
}

/// The characters a refusal names rather than prints.
///
/// Not a Unicode name table — the entries are the ones that actually produce a
/// target nobody can debug by looking at it: the spaces a formatter emits
/// where you typed U+0020 (modern ICU puts U+202F before AM/PM), the marks
/// with no width at all, and the punctuation a text editor or a designer
/// substitutes. Everything else is printed, which for a visible glyph says
/// more than a name would.
const _confusableNames = <int, String>{
  0x0009: 'TAB',
  0x000A: 'LINE FEED',
  0x000D: 'CARRIAGE RETURN',
  0x0020: 'SPACE',
  0x00A0: 'NO-BREAK SPACE',
  0x00AD: 'SOFT HYPHEN',
  0x2002: 'EN SPACE',
  0x2003: 'EM SPACE',
  0x2007: 'FIGURE SPACE',
  0x2009: 'THIN SPACE',
  0x200A: 'HAIR SPACE',
  0x200B: 'ZERO WIDTH SPACE',
  0x200C: 'ZERO WIDTH NON-JOINER',
  0x200D: 'ZERO WIDTH JOINER',
  0x200E: 'LEFT-TO-RIGHT MARK',
  0x200F: 'RIGHT-TO-LEFT MARK',
  0x2011: 'NON-BREAKING HYPHEN',
  0x2013: 'EN DASH',
  0x2014: 'EM DASH',
  0x2018: 'LEFT SINGLE QUOTATION MARK',
  0x2019: 'RIGHT SINGLE QUOTATION MARK',
  0x201C: 'LEFT DOUBLE QUOTATION MARK',
  0x201D: 'RIGHT DOUBLE QUOTATION MARK',
  0x2026: 'HORIZONTAL ELLIPSIS',
  0x202F: 'NARROW NO-BREAK SPACE',
  0x205F: 'MEDIUM MATHEMATICAL SPACE',
  0x2060: 'WORD JOINER',
  0x3000: 'IDEOGRAPHIC SPACE',
  0xFEFF: 'ZERO WIDTH NO-BREAK SPACE',
};

/// Longest string [visibleTextsOf] reports before truncating with an
/// ellipsis. Screens that render logs or protocol dumps put whole essays in
/// single `Text` widgets, and every one of them rides every reply; the cap
/// bounds the worst screen while leaving ordinary UI copy whole. A truncated
/// text still resolves as a target via `containing` with any prefix.
const visibleTextCap = 200;

/// Every `Text` and `EditableText` currently in the tree, in tree order —
/// the text projection of the screen an agent reads next to the pixels, and
/// the material of the nothing-matches message. Strings longer than
/// [visibleTextCap] are truncated with a trailing `…`.
List<String> visibleTextsOf(WidgetController controller) => [
  for (var widget in controller.widgetList(
    find.byWidgetPredicate((w) => w is Text || w is EditableText),
  ))
    _capped(switch (widget) {
      Text(:var data, :var textSpan) => data ?? textSpan?.toPlainText() ?? '',
      // **An obscured field reports what it draws, not what it holds.** The
      // screenshot in the same reply already renders bullets; the plain value
      // beside it put the password into the agent's transcript, into every log
      // that transcript reaches, and onto disk in the run's journal and in a
      // scenario's captured step. Nothing wants the literal here — a driver
      // that typed it knows it, and matching a field *by* its secret is not a
      // thing worth keeping. The widget's own [EditableText.obscuringCharacter]
      // and the length are what the pixels say, so the projection stays
      // faithful: still one entry, still non-empty, still countable.
      EditableText(
        :var controller,
        :var obscureText,
        :var obscuringCharacter,
      ) =>
        obscureText
            ? obscuringCharacter * controller.text.length
            : controller.text,
      _ => '',
    }),
];

String _capped(String text) => text.length <= visibleTextCap
    ? text
    : '${text.substring(0, visibleTextCap)}…';
