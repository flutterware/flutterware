import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
// ignore: implementation_imports
import 'package:flutterware/src/scenarios/aim.dart';
import 'package:flutterware_app/src/scenarios/aim_overlay.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// What a scenario's next link promises, drawn over the frame it acts on.
///
/// What this is for. In the running studio the mark exists only while a
/// pointer is parked on a next link, over whichever frame that run happened
/// to capture, at whatever size the window is — three variables to hold still
/// before a judgement about a stroke width means anything. Here the frame and
/// the size are fixed and the mark is always up.
///
/// What there is to judge, and the reason for two widths: the step page draws
/// the phone at about a quarter of its logical size, so every stroke here is
/// divided by four before anybody sees it. Does the ring survive that? Does
/// the white halo keep it off a coloured button, or does it just fog the
/// picture? And the tap case is deliberately the awkward one — `tap('Flat
/// white')` resolves the *word*, so the box is the label inside a row four
/// times its height, and the question is whether the pair reads as "here" or
/// as "the wrong thing is boxed".
@Preview(name: 'Scenario aim', group: 'Scenarios', wrapper: wrapInAppTheme)
Widget scenarioAim() => const _Sheet();

@Preview(
  name: 'Scenario aim · dark',
  group: 'Scenarios',
  wrapper: wrapInDarkTheme,
)
Widget scenarioAimDark() => const _Sheet();

/// The verbs that put no pointer down anywhere.
///
/// What there is to judge. `enterText` focuses an editable and pushes a
/// value, and `scrollTo` and `keyboard` act on a whole region — so none of
/// the three may wear a contact ring, and the question is whether what
/// replaces it survives the same quarter scale. Two things were measured to
/// fail here and are worth not re-inventing: a thin arrow across a pane
/// disappears at the small size, and `show` and `hide` become the same
/// picture if the only thing separating them is the wedge inside the band.
/// Hence a fill on one and a hollow on the other.
@Preview(
  name: 'Scenario aim · no finger',
  group: 'Scenarios',
  wrapper: wrapInAppTheme,
)
Widget scenarioAimNoFinger() => const _NoFingerSheet();

@Preview(
  name: 'Scenario aim · no finger · dark',
  group: 'Scenarios',
  wrapper: wrapInDarkTheme,
)
Widget scenarioAimNoFingerDark() => const _NoFingerSheet();

/// The verbs that put a finger down, at the size the step page draws them and
/// at one big enough to see what is actually being painted.
class _Sheet extends StatelessWidget {
  const _Sheet();

  /// The label inside the second row — what a text target resolves to, and
  /// four times smaller than the row that handles the tap.
  static const _label = ScenarioAim(x: 112, y: 318, width: 82, height: 22);

  /// What a point verb leaves behind: the coordinate, and a box of no size.
  ///
  /// The last column is here so the ring can be checked for company. An
  /// empty rect is not nothing to `drawRect` — a 2pt stroke on one paints a
  /// dot at the point, which was measured here and reads as a mark somebody
  /// chose rather than as an accident — so the painter drops the outline
  /// for an empty box, and this column is what says it still does.
  static const _point = ScenarioAim(x: 153, y: 329, width: 0, height: 0);

  @override
  Widget build(BuildContext context) => Container(
    color: context.colors.panel2,
    padding: const EdgeInsets.all(24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var (verb, aim) in [
          ('tap', _label),
          ('longPress', _label),
          (
            'drag',
            const ScenarioAim(
              x: 112,
              y: 318,
              width: 82,
              height: 22,
              dx: 0,
              dy: -190,
            ),
          ),
          ('tapAt', _point),
        ]) ...[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(verb, style: context.type.sectionLabel),
              const SizedBox(height: 8),
              // The big one to see what is painted, the small one because
              // that is the size it is actually seen at. 189 rather than the
              // 260 three columns allowed: each column carries a trailing
              // 24pt gap, so four of them have to fit the 852 left inside the
              // 900 the studio stages a desktop subtree at — and an overflow
              // here is only ever a red box in a picture nobody lays out.
              _Phone(width: 189, verb: verb, aim: aim, picture: _menu),
              const SizedBox(height: 12),
              _Phone(width: 110, verb: verb, aim: aim, picture: _menu),
            ],
          ),
          const SizedBox(width: 24),
        ],
      ],
    ),
  );
}

/// `enterText`, `scrollTo` and `keyboard`, on a screen that has a field and a
/// list to act on.
///
/// The whole phone rather than a band of it: two of these three marks are
/// about the bottom of the screen and one about the top, and a crop that fits
/// them all is the phone.
class _NoFingerSheet extends StatelessWidget {
  const _NoFingerSheet();

  /// The field the search screen puts at the top — an `enterText` aims at the
  /// editable, so this is the text area rather than the decoration around it.
  static const _field = ScenarioAim(x: 24, y: 130, width: 342, height: 52);

  /// Everything under the field: the viewport a `scrollTo` would walk.
  static const _viewport = ScenarioAim(
    x: 0,
    y: 196,
    width: 390,
    height: 648,
    toward: 'down',
  );

  /// An iPhone 16's keyboard, which is what the devices table measures. The
  /// band arriving and the band leaving are the same rect and differ by one
  /// word — which is the whole of what the painter has to tell them apart by.
  static const _rising = ScenarioAim(
    x: 0,
    y: 844 - 336,
    width: 390,
    height: 336,
    toward: 'up',
  );
  static const _leaving = ScenarioAim(
    x: 0,
    y: 844 - 336,
    width: 390,
    height: 336,
    toward: 'down',
  );

  /// The big phone's width.
  ///
  /// Five of these have to sit side by side on the plain rectangle the studio
  /// stages a desktop subtree at — 900×700, because a window has no true size
  /// and `PreviewCanvas.defaultDevice` therefore stages none. Five columns and
  /// four gaps in 900 less its padding leaves 154 each, so: 150.
  ///
  /// It was 200, which wanted 1100 and overflowed by 248 — and the column it
  /// made was 56 too tall as well. Neither showed up as anything but a red
  /// box, since an overflow is reported from layout and this sheet is only
  /// ever looked at as a picture.
  static const _big = 150.0;

  /// And the small one, which is the size the step page actually draws a mark
  /// at. This one is a measurement rather than a layout choice, so it does not
  /// move — the whole question the sheet asks is whether a mark still reads
  /// here.
  static const _small = 110.0;

  @override
  Widget build(BuildContext context) => Container(
    color: context.colors.panel2,
    padding: const EdgeInsets.all(24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 20,
      children: [
        for (var (label, verb, aim) in [
          ('enterText', 'enterText', _field),
          ('scrollTo', 'scrollTo', _viewport),
          // The no-op: the target is already wholly inside the pane, so
          // there is no direction to promise. Onstage-ness is deliberately
          // not the test — a row can be built, onstage and a screenful above
          // the viewport, and the walk ends with an `ensureVisible` that goes
          // and gets it.
          (
            'scrollTo · already here',
            'scrollTo',
            const ScenarioAim(x: 24, y: 306, width: 342, height: 84),
          ),
          ('keyboard.show', 'keyboard', _rising),
          ('keyboard.hide', 'keyboard', _leaving),
        ])
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: context.type.sectionLabel),
              const SizedBox(height: 8),
              _Phone(
                width: _big,
                verb: verb,
                aim: aim,
                picture: _search,
                band: 844,
              ),
              const SizedBox(height: 12),
              _Phone(
                width: _small,
                verb: verb,
                aim: aim,
                picture: _search,
                band: 844,
              ),
            ],
          ),
      ],
    ),
  );
}

/// The picture and the mark in the guest's own logical box, scaled down as one
/// — which is exactly what the step page's `FittedBox` does to `FramedShot`,
/// and the only arrangement in which the overlay needs no transform.
class _Phone extends StatelessWidget {
  const _Phone({
    required this.width,
    required this.verb,
    required this.aim,
    required this.picture,
    this.band = 470,
  });

  final double width;
  final String verb;
  final ScenarioAim aim;
  final ui.Image Function() picture;

  /// How much of the phone is shown — the band the mark is in. Cropped rather
  /// than shrunk, because the whole question is how the mark reads at the
  /// scale the step page draws it, and a scale chosen to fit this page on a
  /// screen would answer a different one.
  final double band;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: width * band / 390,
    child: FittedBox(
      child: ClipRect(
        child: SizedBox(
          width: 390,
          height: band,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            maxHeight: 844,
            child: SizedBox(
              width: 390,
              height: 844,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RawImage(image: picture(), fit: BoxFit.fill),
                  ScenarioAimOverlay(aim: aim, verb: verb),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A drink menu: a bar, four rows, each an icon square and two lines of text.
///
/// Drawn rather than loaded, for the reason `run_screen_picture` gives: no
/// asset, no decode, and `toImageSync` puts it in the first frame. Scaled
/// before anything is drawn, for the reason it gives too.
ui.Image _menu() {
  const width = 390.0;
  const height = 844.0;
  var recorder = ui.PictureRecorder();
  var canvas = Canvas(recorder)
    ..scale(2)
    ..drawRect(
      const Rect.fromLTWH(0, 0, width, height),
      Paint()..color = const Color(0xFFFDF7F2),
    )
    ..drawRect(
      const Rect.fromLTWH(0, 0, width, 120),
      Paint()..color = const Color(0xFF7C3A16),
    );
  for (var i = 0; i < 4; i++) {
    var top = 160.0 + i * 140;
    canvas
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(24, top, 342, 84),
          const Radius.circular(14),
        ),
        Paint()..color = Colors.white,
      )
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(40, top + 14, 56, 56),
          const Radius.circular(12),
        ),
        // The third row is the tapped one, and it is the accent-ish colour on
        // purpose: a mark that only reads on white is a mark that does not.
        Paint()
          ..color = i == 1 ? const Color(0xFF2563EB) : const Color(0xFFEADFD4),
      )
      // The label, and the line under it.
      ..drawRect(
        Rect.fromLTWH(112, top + 18, 82, 22),
        Paint()..color = const Color(0xFF44322A),
      )
      ..drawRect(
        Rect.fromLTWH(112, top + 50, 180, 12),
        Paint()..color = const Color(0xFFC9BAB0),
      );
  }
  return recorder.endRecording().toImageSync(
    (width * 2).round(),
    (height * 2).round(),
  );
}

/// A search screen: a bar, a field, and a list under it — the stage the
/// no-finger verbs need, since all three are about a field or a list.
ui.Image _search() {
  const width = 390.0;
  const height = 844.0;
  const field = Rect.fromLTWH(24, 130, 342, 52);
  var recorder = ui.PictureRecorder();
  var canvas = Canvas(recorder)
    ..scale(2)
    ..drawRect(
      const Rect.fromLTWH(0, 0, width, height),
      Paint()..color = const Color(0xFFFDF7F2),
    )
    ..drawRect(
      const Rect.fromLTWH(0, 0, width, 110),
      Paint()..color = const Color(0xFF7C3A16),
    )
    ..drawRRect(
      RRect.fromRectAndRadius(field, const Radius.circular(14)),
      Paint()..color = Colors.white,
    )
    // The placeholder the typed text replaces.
    ..drawRect(
      const Rect.fromLTWH(44, 148, 110, 16),
      Paint()..color = const Color(0xFFC9BAB0),
    );
  for (var i = 0; i < 6; i++) {
    var top = 206.0 + i * 100;
    canvas
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(24, top, 342, 84),
          const Radius.circular(14),
        ),
        Paint()..color = Colors.white,
      )
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(40, top + 14, 56, 56),
          const Radius.circular(12),
        ),
        Paint()
          ..color = i == 1 ? const Color(0xFF2563EB) : const Color(0xFFEADFD4),
      )
      ..drawRect(
        Rect.fromLTWH(112, top + 18, 82, 22),
        Paint()..color = const Color(0xFF44322A),
      )
      ..drawRect(
        Rect.fromLTWH(112, top + 50, 180, 12),
        Paint()..color = const Color(0xFFC9BAB0),
      );
  }
  return recorder.endRecording().toImageSync(
    (width * 2).round(),
    (height * 2).round(),
  );
}
