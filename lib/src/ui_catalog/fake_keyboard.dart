/// The keyboard that is not there: what a screen loses when one comes up, and
/// the slab that stands in for it.
///
/// Painted, never built. A keyboard composed of widgets would put key caps
/// in front of `find.text`, a hundred nodes into the semantics and transcript
/// audits, and a wall of junk into `screen()`. One [CustomPainter] under an
/// [ExcludeSemantics] is one leaf, one paint call, and invisible to every
/// finder.
///
/// Glyphs only where they are the same in every language. No letter is ever
/// drawn: a letter would need a per-locale layout to not be a lie, and rows of
/// rounded rectangles say *keyboard* without claiming a language. But `@`, `.`,
/// `/`, `.com` and the digits sit in the same place on an AZERTY, a Cyrillic
/// and a QWERTY keyboard — and they are precisely the keys that say *which*
/// keyboard it is. Leaving those blank is what made an email keyboard and a
/// text one tell apart only by the width of a space bar.
///
/// Every label is ASCII, deliberately: a glyph the rendering font does not
/// carry comes out as a tofu box, which is worse than the blank key it
/// replaced. That is why the backspace on the keypad is drawn as a shape
/// rather than as `⌫`.
///
/// Shared by both lanes on purpose — the guest drives it from a
/// [TextInputControl], a scenario drives it from the test binding, and the
/// picture they produce has to be the same picture.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../devices.dart';

/// A screen with [height] logical pixels of keyboard across the bottom of it.
///
/// Two things at once, because they are one fact: the [MediaQuery] the app
/// reads and the pixels a capture contains. Splitting them is how a fake
/// keyboard ends up as artwork the layout does not know about — or as an inset
/// with nothing on screen to explain where the bottom third went.
///
/// Zero is free: no stack, no painter, nothing added to the tree at all.
class FakeKeyboard extends StatelessWidget {
  const FakeKeyboard({
    super.key,
    required this.height,
    this.platform,
    this.variant = KeyboardVariant.letters,
    required this.child,
  });

  /// How tall, in logical pixels. Zero for a keyboard that is down.
  final double height;

  /// Which keyboard to draw. Null takes the iOS tint, which is also what a
  /// device with no platform of its own would be shown on.
  final DevicePlatform? platform;

  /// Which keys to draw — see [FakeKeyboardPainter.variant].
  final KeyboardVariant variant;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var media = MediaQuery.of(context);
    // **The wrappers are unconditional, and that is not tidiness.** A widget
    // that returns its child bare at zero and wraps it at 336 *reparents the
    // app* the moment the keyboard moves: every `State` under it is disposed
    // and rebuilt, which loses the focus, closes the text input connection and
    // empties whatever had been typed. Measured — a scenario tapping a field
    // saw `TextInput.show` immediately followed by `clearClient`, and the
    // keyboard it had just asked for went straight back down.
    //
    // So the shape stays put and only the numbers move. Down costs one
    // `MediaQuery` with the data it was given and a zero-height band.
    return MediaQuery(
      // The arithmetic, and all three numbers of it. Getting only the first is
      // how a fake keyboard ends up with a `SafeArea` floating 34 points above
      // it: `MediaQueryData.fromView` reads `view.padding` directly rather
      // than deriving it from the insets, so a driver that raises the insets
      // and leaves the padding alone is describing a phone that does not
      // exist. A real embedder eats the home indicator — measured on eight
      // simulators and an emulator, `padding.bottom` is 0 on every one of them
      // while the keyboard is up — and `viewPadding` is what still remembers
      // the device underneath.
      data: height <= 0
          ? media
          : media.copyWith(
              padding: media.padding.copyWith(
                bottom: math.max(0, media.padding.bottom - height),
              ),
              viewInsets: media.viewInsets.copyWith(bottom: height),
            ),
      child: FakeKeyboardSlab(
        height: height,
        platform: platform,
        variant: variant,
        child: child,
      ),
    );
  }
}

/// The slab alone, over [child], with none of the arithmetic.
///
/// Its own widget because the two lanes divide the work differently. In a
/// preview the numbers are a `MediaQuery` this package writes, so [FakeKeyboard]
/// does both halves in one place. In a scenario they are the *view's* — set on
/// the binding's test values exactly as a real embedder would report them, so
/// that every `MediaQuery.fromView` in the app sees them and not only the
/// subtree under one widget — and all that is left for the tree is the picture
/// and the occlusion. Which is this.
class FakeKeyboardSlab extends StatelessWidget {
  const FakeKeyboardSlab({
    super.key,
    required this.height,
    this.platform,
    this.variant = KeyboardVariant.letters,
    required this.child,
  });

  final double height;
  final DevicePlatform? platform;
  final KeyboardVariant variant;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      // Non-directional on purpose: the default `AlignmentDirectional.topStart`
      // needs a `Directionality`, and this widget sits **above** the app — in
      // the scenario lane there is no `MaterialApp` over it to supply one, and
      // asking a keyboard to know the reading direction to draw a band at the
      // bottom of the screen would be inventing a dependency.
      alignment: Alignment.topLeft,
      children: [
        child,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          // Zero when it is down — kept in the tree rather than removed, for
          // the reason [FakeKeyboard] gives: a child list that changes length
          // is a child list that can reparent, and reparenting the app is how
          // a keyboard ends up wiping the field that asked for it.
          height: math.max(0, height),
          // **It hit-tests true**, because that is what a keyboard does: a tap
          // that lands on it does not reach the app. Absorbing rather than
          // ignoring is the whole difference between a picture of a keyboard
          // and a keyboard.
          child: ExcludeSemantics(
            child: AbsorbPointer(
              child: CustomPaint(
                size: Size.infinite,
                painter: FakeKeyboardPainter(
                  platform: platform,
                  variant: variant,
                  dark:
                      MediaQuery.platformBrightnessOf(context) ==
                      Brightness.dark,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The slab: a suggestion strip, three letter rows, a bottom row with a space
/// bar, and whatever band the platform leaves below it.
///
/// Proportional to the box it is given rather than to a key size, because the
/// box is a measurement — an iPhone SE's 260 points and an iPad Pro's 501 hold
/// the same rows at different sizes, which is what real keyboards do.
class FakeKeyboardPainter extends CustomPainter {
  FakeKeyboardPainter({
    required this.platform,
    required this.dark,
    this.variant = KeyboardVariant.letters,
  });

  final DevicePlatform? platform;
  final bool dark;

  /// Which keyboard to draw. **The picture changes on every device**, even
  /// where the height does not: an iPad gives a number field the same 405.5
  /// points as a text field and a completely different set of keys, and a
  /// screenshot that showed letters there would be describing a field the app
  /// never asked for.
  final KeyboardVariant variant;

  bool get _android => platform == DevicePlatform.android;

  /// The ten characters on every locale's number pad, in the order the grid
  /// draws them — `1`–`9` across three rows, then `0` beside the backspace.
  static const _keypadDigits = [
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '0',
  ];

  /// Every label this keyboard draws, in drawing order.
  ///
  /// Exists so a test can hold the picture to account. A label here is
  /// painted, not built, so no finder can see it and no `screen()` reports it —
  /// which is the property that keeps a keyboard out of the app's text
  /// projection, and also the property that let a variant go missing while
  /// every assertion still passed. This is the seam that closes it: the email
  /// keyboard draws an `@`, and a test can say so.
  List<String> get labels => variant == KeyboardVariant.keypad
      ? _keypadDigits
      : [for (var (_, _, label) in _bottomRow) ?label];

  /// The slab itself.
  Color get _ground => switch ((_android, dark)) {
    (true, false) => const Color(0xFFEDEFF2),
    (true, true) => const Color(0xFF1F2023),
    (false, false) => const Color(0xFFD1D4DB),
    (false, true) => const Color(0xFF1C1C1E),
  };

  /// An ordinary letter key.
  Color get _key => switch ((_android, dark)) {
    (true, false) => const Color(0xFFFFFFFF),
    (true, true) => const Color(0xFF3C4043),
    (false, false) => const Color(0xFFFFFFFF),
    (false, true) => const Color(0xFF4A4A4E),
  };

  /// Shift, backspace, return — the ones a real keyboard draws darker.
  Color get _modifier => switch ((_android, dark)) {
    (true, false) => const Color(0xFFDCE0E5),
    (true, true) => const Color(0xFF2B2D30),
    (false, false) => const Color(0xFFAEB3BD),
    (false, true) => const Color(0xFF313134),
  };

  /// The suggestion pills, which are text on a real keyboard and shapes here.
  Color get _hint => _modifier.withValues(alpha: dark ? 0.9 : 0.75);

  /// What a key's label is drawn in.
  Color get _ink => dark ? const Color(0xFFF2F2F7) : const Color(0xFF1C1C1E);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _ground);
    // The one line that says where the app stops. A slab the same value as a
    // white app has no edge at all, and the app's own bottom row then looks
    // like the keyboard's top row.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, 0.5),
      Paint()..color = const Color(0x22000000),
    );

    // The bands, top to bottom. The suggestion strip is inside the measured
    // number rather than beside it, and so is the home indicator, which is
    // why the rows stop short of the bottom.
    //
    // **A keypad has no strip**, and that is not a drawing decision: a digit
    // pad predicts nothing, which is most of why it is the shorter keyboard
    // in the first place.
    var strip = variant == KeyboardVariant.keypad ? 0.0 : size.height * 0.14;
    var foot = size.height * (_android ? 0.05 : 0.10);
    var rowsHeight = size.height - strip - foot;
    if (rowsHeight <= 0) return;

    if (strip > 0) {
      _paintStrip(canvas, Rect.fromLTWH(0, 0, size.width, strip));
    }

    var gap = math.max(1.0, rowsHeight * 0.055);
    var rowHeight = (rowsHeight - gap * 4) / 4;
    if (rowHeight <= 0) return;
    var margin = size.width * 0.012;
    var radius = Radius.circular(_android ? rowHeight * 0.16 : rowHeight * 0.2);

    double rowTop(int index) => strip + gap * (index + 1) + rowHeight * index;

    if (variant == KeyboardVariant.keypad) {
      _paintKeypad(canvas, size, rowTop, rowHeight, margin, radius, gap);
      return;
    }

    // 10, 9 inset by half a key, then shift + 7 + backspace. The alphabet
    // every Latin layout is some permutation of.
    _paintKeys(canvas, size, rowTop(0), rowHeight, margin, radius, 10, gap);
    _paintKeys(
      canvas,
      size,
      rowTop(1),
      rowHeight,
      margin + (size.width - margin * 2) / 20,
      radius,
      9,
      gap,
    );
    _paintWeighted(
      canvas,
      size,
      rowTop(2),
      rowHeight,
      margin,
      radius,
      gap,
      const [
        (1.5, true, null),
        (1, false, null),
        (1, false, null),
        (1, false, null),
        (1, false, null),
        (1, false, null),
        (1, false, null),
        (1, false, null),
        (1.5, true, null),
      ],
    );
    // The bottom row is the whole of what a reader can see the *type* in. A
    // real email keyboard grows an `@` and a dot here, a URL keyboard a slash
    // and a `.com`, and both take the width out of the space bar — which is
    // exactly what makes them recognisable at a glance without a single glyph
    // being drawn.
    _paintWeighted(
      canvas,
      size,
      rowTop(3),
      rowHeight,
      margin,
      radius,
      gap,
      _bottomRow,
    );
  }

  /// `(weight, isModifier, label)` per key, for the row that says which
  /// keyboard this is.
  ///
  /// The labels are the whole point of this row. A real email keyboard
  /// grows an `@` and a dot here and a URL one a slash and a `.com`, both at
  /// the space bar's expense — and drawn as bare rectangles the two rows
  /// differ only in how wide the middle key is, which nobody reads as a
  /// keyboard type. With the two characters on them it needs no explaining.
  List<(double, bool, String?)> get _bottomRow => switch (variant) {
    KeyboardVariant.email => [
      (1.4, true, _numbers),
      (1.0, false, '@'),
      (1.0, false, '.'),
      (3.4, false, null),
      (1.9, true, null),
    ],
    // **`.com` stands exactly where the space bar does**, and that is the
    // whole of the difference from the row above it: a URL has no spaces in
    // it, so the platform spends the space bar's width on the one string every
    // address ends with. Drawn as a narrower key with a blank one beside it,
    // that blank read as a key nobody could name.
    KeyboardVariant.url => [
      (1.4, true, _numbers),
      (1.0, false, '.'),
      (1.0, false, '/'),
      (3.4, false, '.com'),
      (1.9, true, null),
    ],
    // Android splits the same width between a comma, a full stop and a smaller
    // enter; iOS gives the return key a fifth of the row.
    _ =>
      _android
          ? [
              (1.4, true, _numbers),
              (1, true, ','),
              (5, false, null),
              (1, true, '.'),
              (1.4, true, null),
            ]
          : [
              (1.4, true, _numbers),
              (1.1, true, null),
              (4.6, false, null),
              (1.9, true, null),
            ],
  };

  /// What the key that switches to digits is called — `?123` on Android and
  /// `123` on iOS.
  ///
  /// Platform-aware on every row it appears on, which it was not: the letters
  /// row spelled it the platform's way and the email and URL rows spelled it
  /// iOS's, so an Android email keyboard carried a key Gboard does not have.
  String get _numbers => _android ? '?123' : '123';

  /// A digit pad: three columns, four rows, and nothing that looks like a
  /// letter.
  ///
  /// Unmistakable is the whole job. A shorter band drawn with ten-key rows
  /// would be a picture of a keyboard the app did not ask for, and the reader
  /// would have no way to tell the form wanted digits.
  void _paintKeypad(
    Canvas canvas,
    Size size,
    double Function(int) rowTop,
    double rowHeight,
    double margin,
    Radius radius,
    double gap,
  ) {
    var available = size.width - margin * 2;
    var keyGap = gap * 0.6;
    var width = (available - keyGap * 2) / 3;
    for (var row = 0; row < 4; row++) {
      for (var column = 0; column < 3; column++) {
        // 1–9, then the last row: nothing, 0, backspace. The empty corner is
        // as much a part of a number pad's silhouette as the digits are.
        var lastRow = row == 3;
        if (lastRow && column == 0) continue;
        var backspace = lastRow && column == 2;
        var rect = Rect.fromLTWH(
          margin + column * (width + keyGap),
          rowTop(row),
          width,
          rowHeight,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, radius),
          Paint()..color = backspace ? _modifier : _key,
        );
        if (backspace) {
          _paintBackspace(canvas, rect);
        } else {
          // The digits, which are the same ten characters on every locale's
          // number pad — so drawing them claims nothing a blank key does not
          // already claim, and says the one thing it cannot.
          _paintLabel(
            canvas,
            rect,
            _keypadDigits[lastRow ? 9 : row * 3 + column],
          );
        }
      }
    }
  }

  /// The backspace arrow, as a shape.
  ///
  /// Drawn rather than written because `⌫` is the one mark this keyboard wants
  /// that a rendering font may not carry, and a missing glyph is a tofu box —
  /// which on a key that is otherwise blank reads as a bug rather than as a
  /// character.
  void _paintBackspace(Canvas canvas, Rect key) {
    var height = key.height * 0.26;
    var width = height * 1.5;
    var centre = key.center;
    var tip = centre.dx - width / 2;
    var right = centre.dx + width / 2;
    canvas.drawPath(
      Path()
        ..moveTo(tip, centre.dy)
        ..lineTo(tip + height / 2, centre.dy - height / 2)
        ..lineTo(right, centre.dy - height / 2)
        ..lineTo(right, centre.dy + height / 2)
        ..lineTo(tip + height / 2, centre.dy + height / 2)
        ..close(),
      Paint()..color = _ink.withValues(alpha: 0.65),
    );
  }

  /// Three pills where a real keyboard puts the words it is guessing at.
  void _paintStrip(Canvas canvas, Rect band) {
    var paint = Paint()..color = _hint;
    var pill = band.height * 0.34;
    var y = band.center.dy - pill / 2;
    // Uneven, because guesses are words rather than a measured set of three.
    const widths = [0.16, 0.22, 0.13];
    var x = band.width * 0.10;
    for (var (index, fraction) in widths.indexed) {
      var width = band.width * fraction;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x + index * band.width * 0.07, y, width, pill),
          Radius.circular(pill / 2),
        ),
        paint,
      );
      x += width;
    }
  }

  void _paintKeys(
    Canvas canvas,
    Size size,
    double top,
    double height,
    double margin,
    Radius radius,
    int count,
    double gap,
  ) {
    var available = size.width - margin * 2;
    var keyGap = gap * 0.6;
    var width = (available - keyGap * (count - 1)) / count;
    var paint = Paint()..color = _key;
    for (var i = 0; i < count; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(margin + i * (width + keyGap), top, width, height),
          radius,
        ),
        paint,
      );
    }
  }

  /// A row of keys of unequal width — `(weight, isModifier, label)` each.
  void _paintWeighted(
    Canvas canvas,
    Size size,
    double top,
    double height,
    double margin,
    Radius radius,
    double gap,
    List<(double, bool, String?)> keys,
  ) {
    var available = size.width - margin * 2;
    var keyGap = gap * 0.6;
    var total = keys.fold<double>(0, (sum, key) => sum + key.$1);
    var unit = (available - keyGap * (keys.length - 1)) / total;
    var x = margin;
    for (var (weight, modifier, label) in keys) {
      var width = unit * weight;
      var rect = Rect.fromLTWH(x, top, width, height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, radius),
        Paint()..color = modifier ? _modifier : _key,
      );
      if (label != null) _paintLabel(canvas, rect, label);
      x += width + keyGap;
    }
  }

  /// One key's label, centred, shrunk to fit rather than allowed to spill.
  ///
  /// Laid out unconstrained first and then re-laid at a scaled size, because
  /// `maxWidth` on a `TextPainter` wraps rather than shrinks — a `.com` on a
  /// narrow key would come out as two lines rather than as smaller text.
  ///
  /// Every painter made here is disposed here, including the one that
  /// turned out too wide and was never drawn. A `TextPainter` owns a
  /// `ui.Paragraph`, which is engine memory a Dart garbage collection has to
  /// come round to; a keypad is ten of them, the slide repaints on every frame
  /// it moves, and a suite raises a keyboard on most of its steps. The
  /// paragraph is safe to release the moment it has been recorded — the
  /// display list keeps its own reference to what it drew, which is why
  /// `RenderParagraph` may dispose a painter it has painted a hundred times.
  void _paintLabel(Canvas canvas, Rect key, String label) {
    var size = key.height * 0.34;
    var painter = _layOut(label, size);
    var room = key.width * 0.78;
    if (painter.width > room && painter.width > 0) {
      var wanted = size * room / painter.width;
      painter.dispose();
      painter = _layOut(label, wanted);
    }
    painter.paint(
      canvas,
      Offset(
        key.center.dx - painter.width / 2,
        key.center.dy - painter.height / 2,
      ),
    );
    painter.dispose();
  }

  TextPainter _layOut(String label, double fontSize) => TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(
        color: _ink,
        // Never zero or below: a key laid out to nothing would otherwise ask
        // the engine for a font size it refuses.
        fontSize: math.max(1, fontSize),
        // Whatever the rendering lane's default face is. Naming a family here
        // would be naming one that only one of the two lanes has.
        fontWeight: FontWeight.w400,
        height: 1,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  bool shouldRepaint(FakeKeyboardPainter old) =>
      old.platform != platform || old.dark != dark || old.variant != variant;
}

/// [FakeKeyboardSlab] as tall as the **view** says the keyboard is.
///
/// For the lanes where the numbers are the view's rather than a widget's — a
/// scenario, and the previews harness on `flutter_tester` — which is every
/// lane running under a test binding. Reading the height back off the view is
/// what stops the picture and the layout from being two facts: they are one,
/// and the app met it first.
class ViewKeyboardSlab extends StatelessWidget {
  const ViewKeyboardSlab({
    super.key,
    this.variant = KeyboardVariant.letters,
    required this.child,
  });

  /// Which keys. Defaults to letters, which is what a lane with no field
  /// focused has to assume — a preview harness stages a keyboard from a canvas
  /// and nothing in a cold render ever asks for one.
  final KeyboardVariant variant;

  final Widget child;

  @override
  Widget build(BuildContext context) => FakeKeyboardSlab(
    height: MediaQuery.viewInsetsOf(context).bottom,
    variant: variant,
    // The staged platform, which the run has already set from the device —
    // the same fact the app's own `.adaptive` widgets read.
    platform: defaultTargetPlatform == TargetPlatform.android
        ? DevicePlatform.android
        : DevicePlatform.ios,
    child: child,
  );
}
