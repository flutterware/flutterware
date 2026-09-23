import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/devices.dart';
import 'package:flutterware/src/ui_catalog/fake_keyboard.dart';

/// The two things a fake keyboard has to be: an inset the layout meets, and a
/// surface a finger cannot get past.
///
/// The arithmetic is asserted against the *measured* behaviour of a real
/// device rather than against what looks reasonable — `padding.bottom` reading
/// zero with the keyboard up is a measurement from eight simulators and an
/// emulator, and a `SafeArea` floating 34 points above the keys is what
/// getting it wrong looks like.
void main() {
  /// A phone-shaped screen with a notch and a home indicator, and [child]
  /// laid out on it under [keyboard] points of keyboard.
  Future<MediaQueryData> pump(
    WidgetTester tester, {
    required double keyboard,
    KeyboardVariant variant = KeyboardVariant.letters,
    Widget child = const SizedBox.expand(),
  }) async {
    // The surface itself, not only what `MediaQuery` claims: a `Scaffold`
    // sizes to its constraints, so a test that moved the reported size and
    // left the 800×600 test view alone would assert the arithmetic and prove
    // nothing about the layout meeting it.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late MediaQueryData seen;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          padding: EdgeInsets.only(top: 47, bottom: 34),
          viewPadding: EdgeInsets.only(top: 47, bottom: 34),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: FakeKeyboard(
            height: keyboard,
            platform: DevicePlatform.ios,
            variant: variant,
            child: Builder(
              builder: (context) {
                seen = MediaQuery.of(context);
                return child;
              },
            ),
          ),
        ),
      ),
    );
    return seen;
  }

  group('the keys that say which keyboard it is carry their characters', () {
    // **The one thing a finder cannot check.** Every label here is painted, so
    // it is invisible to `find.text`, to `screen()` and to the transcript
    // audits — which is exactly the property that keeps a keyboard out of the
    // app's own text projection, and exactly the property that let a variant
    // reach the painter and change nothing anybody could assert on.
    FakeKeyboardPainter painterFor(KeyboardVariant variant) =>
        FakeKeyboardPainter(
          platform: DevicePlatform.ios,
          dark: false,
          variant: variant,
        );

    test('an email keyboard draws an @ and a dot', () {
      expect(painterFor(KeyboardVariant.email).labels, ['123', '@', '.']);
    });

    test('a url keyboard draws a slash and a .com, and no space bar', () {
      expect(painterFor(KeyboardVariant.url).labels, ['123', '.', '/', '.com']);
    });

    test('a keypad draws the ten digits', () {
      expect(painterFor(KeyboardVariant.keypad).labels, [
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
      ]);
    });

    test('and Android spells the digits key its own way, on every row', () {
      FakeKeyboardPainter android(KeyboardVariant variant) =>
          FakeKeyboardPainter(
            platform: DevicePlatform.android,
            dark: false,
            variant: variant,
          );
      // It was platform-aware on the letters row and hard-coded to iOS's `123`
      // on the other two, so an Android email keyboard carried a key Gboard
      // does not have.
      expect(android(KeyboardVariant.letters).labels.first, '?123');
      expect(android(KeyboardVariant.email).labels.first, '?123');
      expect(android(KeyboardVariant.url).labels.first, '?123');
    });

    test('and letters claim no language at all', () {
      // `123` is the only mark on it, and it is a mark every locale's keyboard
      // carries. Nothing here spells a letter, because a letter would need a
      // layout that is a lie on an AZERTY.
      expect(painterFor(KeyboardVariant.letters).labels, ['123']);
    });

    test('a repaint follows the labels, not only the height', () {
      var email = painterFor(KeyboardVariant.email);
      expect(email.shouldRepaint(painterFor(KeyboardVariant.url)), isTrue);
      expect(email.shouldRepaint(painterFor(KeyboardVariant.email)), isFalse);
    });
  });

  group('the arithmetic', () {
    testWidgets('the insets rise by exactly the keyboard', (tester) async {
      var media = await pump(tester, keyboard: 336);
      expect(media.viewInsets.bottom, 336);
    });

    testWidgets('and the keyboard eats the home indicator', (tester) async {
      var media = await pump(tester, keyboard: 336);
      // Not 34, and not 34 subtracted from something: a keyboard taller than
      // the safe area leaves none of it, which is what every device measured
      // on 2026-08-21 reported.
      expect(media.padding.bottom, 0);
      // The rest of the device is untouched — a keyboard is not a full-screen
      // change of scenery.
      expect(media.padding.top, 47);
    });

    testWidgets('what is left of a device the keyboard does not cover', (
      tester,
    ) async {
      // A keyboard shorter than the safe area is not a real phone; it is what
      // the arithmetic has to keep answering sensibly anyway.
      var media = await pump(tester, keyboard: 10);
      expect(media.padding.bottom, 24);
    });

    testWidgets('viewPadding still remembers the device', (tester) async {
      var media = await pump(tester, keyboard: 336);
      // The one number `MediaQueryData.fromView` does *not* derive, and the
      // one a layout asks when it wants the device rather than the moment.
      expect(media.viewPadding.bottom, 34);
    });

    testWidgets('a keyboard that is down changes nothing at all', (
      tester,
    ) async {
      var media = await pump(tester, keyboard: 0);
      expect(media.viewInsets.bottom, 0);
      expect(media.padding.bottom, 34);
      // The band is in the tree and it is nothing: zero high, so it absorbs
      // nothing and paints nothing. See the remount test below for why it is
      // kept rather than removed.
      expect(tester.getSize(find.byType(AbsorbPointer)).height, 0);
    });

    testWidgets('raising it does not remount the app', (tester) async {
      // **The bug this pins, measured.** A wrapper that returns its child bare
      // at zero and wraps it at 336 *reparents* the app when the keyboard
      // moves: every `State` under it is disposed and rebuilt. In a scenario
      // that showed up as `TextInput.show` immediately followed by
      // `clearClient` — the field asked for a keyboard and then lost the focus
      // that asked, so the keyboard it had just raised went straight back
      // down. In a preview it would empty whatever had been typed.
      var key = GlobalKey<_LivesState>();
      await pump(tester, keyboard: 0, child: _Lives(key: key));
      key.currentState!.value = 'typed';
      await pump(tester, keyboard: 336, child: _Lives(key: key));
      expect(key.currentState!.value, 'typed');
      expect(key.currentState!.mounts, 1);
    });
  });

  group('the slab', () {
    testWidgets('a real layout meets the smaller screen', (tester) async {
      var body = GlobalKey();
      await pump(
        tester,
        keyboard: 336,
        child: MaterialApp(
          home: Scaffold(body: SizedBox.expand(key: body)),
        ),
      );
      // 844 minus the keyboard, which is the whole point of the feature — and
      // measured on the *body* rather than on the `Scaffold`, which goes on
      // filling the screen while it hands its body what is left.
      expect(tester.getSize(find.byKey(body)).height, 844 - 336);
    });

    testWidgets('a tap that lands on it does not reach the app', (
      tester,
    ) async {
      var taps = 0;
      await pump(
        tester,
        keyboard: 336,
        child: GestureDetector(
          // Opaque, because an empty box hit-tests as nothing and a detector
          // that defers to its child would count no taps anywhere — a test
          // that then passed on the second half for the wrong reason.
          behavior: HitTestBehavior.opaque,
          onTap: () => taps++,
          child: const SizedBox.expand(),
        ),
      );
      // Above the band: the app hears it.
      await tester.tapAt(const Offset(195, 300));
      expect(taps, 1);
      // On the band: it does not, because that is what a keyboard does.
      await tester.tapAt(const Offset(195, 700));
      expect(taps, 1);
    });

    testWidgets('it is invisible to a finder and to a screen reader', (
      tester,
    ) async {
      var handle = tester.ensureSemantics();
      await pump(
        tester,
        keyboard: 336,
        child: const Center(child: Text('the app')),
      );
      // One leaf, no keys, nothing carrying a word — which is what keeps a
      // keyboard out of `find.text`, out of the transcript audits and out of
      // every `screen()` reply. The app's own node is the *only* one under
      // it: a keyboard built from widgets would have put thirty here.
      expect(tester.getSemantics(find.byType(FakeKeyboard)).childrenCount, 1);
      expect(find.text('the app'), findsOneWidget);
      handle.dispose();
    });
  });

  group('the artwork', () {
    testWidgets('the variant reaches the brush', (tester) async {
      // **Pinned because it silently did not.** `FakeKeyboard` takes the
      // variant, hands the height and the platform to the slab, and once
      // forgot to hand over the third — so the guest knew perfectly well a
      // phone field was focused, reported `variant: keypad` over the wire, and
      // drew ten rows of letters anyway. Nothing about that is visible from
      // either end on its own.
      await pump(tester, keyboard: 291, variant: KeyboardVariant.keypad);
      var paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(AbsorbPointer),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(
        (paint.painter! as FakeKeyboardPainter).variant,
        KeyboardVariant.keypad,
      );
    });

    testWidgets('repaints only when the keyboard it draws changes', (
      tester,
    ) async {
      var ios = FakeKeyboardPainter(platform: DevicePlatform.ios, dark: false);
      expect(
        ios.shouldRepaint(
          FakeKeyboardPainter(platform: DevicePlatform.ios, dark: false),
        ),
        isFalse,
      );
      expect(
        ios.shouldRepaint(
          FakeKeyboardPainter(platform: DevicePlatform.android, dark: false),
        ),
        isTrue,
      );
      expect(
        ios.shouldRepaint(
          FakeKeyboardPainter(platform: DevicePlatform.ios, dark: true),
        ),
        isTrue,
      );
    });

    testWidgets('a band too short for rows paints a slab and stops', (
      tester,
    ) async {
      // Nothing in the table is this short; a `--height` override can make the
      // box one, and a painter that divided by a negative row height would
      // take the whole preview down with it.
      await pump(tester, keyboard: 4);
      expect(tester.takeException(), isNull);
    });
  });
}

/// A widget that remembers whether it has been remounted.
class _Lives extends StatefulWidget {
  const _Lives({super.key});

  @override
  State<_Lives> createState() => _LivesState();
}

class _LivesState extends State<_Lives> {
  String value = '';
  int mounts = 0;

  @override
  void initState() {
    super.initState();
    mounts++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
