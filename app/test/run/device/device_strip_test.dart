import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/run/device/device_settings.dart';
import 'package:flutterware_app/src/run/device_strip.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'fake_process.dart' show SettingLookup;

/// The strip is a View: it takes a list and two callbacks and reads nothing.
/// That is what lets every state below be rendered without a device anywhere,
/// including the two no v1 backend can produce.
void main() {
  group('five chips over eight settings', () {
    test('groups by the noun the backend already assigned', () {
      var chips = deviceChips(_iosDefaults);

      expect(chips.map((c) => c.noun), [
        'Theme',
        'Text',
        'Turn',
        'Lang',
        'A11y',
      ]);
      expect(chips.last.settings.map((s) => s.id), [
        DeviceSettingId.boldText,
        DeviceSettingId.highContrast,
        DeviceSettingId.invertColors,
        DeviceSettingId.disableAnimations,
      ], reason: 'the four flags share a chip and keep their reported order');
    });

    test('the group counts flags that are on, not flags that exist', () {
      // The mockup drew `1 of 2 seen`, which conflated *on* with *observed*.
      // A refused flag is not counted at all — it is listed in the picker with
      // its reason.
      expect(deviceChips(_iosDefaults).last.value, 'off');
      expect(
        deviceChips(_ios(highContrast: 'on', invertColors: 'on')).last.value,
        '2 on',
      );
    });

    test('a chip whose settings are all refused is a dash, not an absence', () {
      var chips = deviceChips([
        const DeviceSetting.unavailable(
          id: DeviceSettingId.boldText,
          noun: 'A11y',
          reason: 'no mechanism',
        ),
      ]);

      expect(chips.single.value, '—');
      expect(chips.single.state, DeviceSettingState.unavailable);
    });

    test('a value nothing answered with is not a default', () {
      // `simctl ui` returns `unknown` and `unsupported` as values and
      // `settings get` returns the string `null`; all three land here, and a
      // quiet chip would report the platform default as the device's answer.
      var chip = deviceChips([
        const DeviceSetting(
          id: DeviceSettingId.brightness,
          noun: 'Theme',
          provenance: DeviceProvenance.unknown,
        ),
      ]).single;

      expect(chip.value, '—');
      expect(chip.atDefault, isFalse);
    });

    test('the display wins over the value where the backend set one', () {
      // Android's text scale is a device setting whose effect is a curve, so
      // the raw `1.5` is drawn as `font_scale 1.5` — a bare number would read
      // as a multiplier.
      var chip = deviceChips([
        const DeviceSetting(
          id: DeviceSettingId.textScale,
          noun: 'Text',
          value: '1.5',
          display: 'font_scale 1.5',
        ),
      ]).single;

      expect(chip.value, 'font_scale 1.5');
    });

    test('one app-scoped setting badges the whole chip', () {
      var chip = deviceChips([
        const DeviceSetting(
          id: DeviceSettingId.language,
          noun: 'Lang',
          value: 'fr-FR',
          scope: DeviceScope.app,
        ),
      ]).single;

      expect(chip.scope, 'per-app');
    });

    test(
      'a refused flag does not stop the rest of its group reading quiet',
      () {
        var chip = deviceChips([
          const DeviceSetting.unavailable(
            id: DeviceSettingId.boldText,
            noun: 'A11y',
            reason: 'no mechanism',
          ),
          const DeviceSetting(
            id: DeviceSettingId.invertColors,
            noun: 'A11y',
            value: 'off',
            atDefault: true,
          ),
        ]).single;

        expect(chip.atDefault, isTrue);
        expect(chip.state, DeviceSettingState.set);
      },
    );
  });

  group('the strip', () {
    Future<void> pump(
      WidgetTester tester,
      List<DeviceSetting> settings, {
      void Function(DeviceSettingId, String)? onSet,
      String? notice,
      bool reading = false,
      // Generous, because this is the test font and not the app's — it draws
      // every glyph a full em wide, so five chips here measure half again what
      // they do in the running studio. The window is resized rather than a
      // `SizedBox` given a width: a box wider than its constraints is clamped
      // to them, so the first draft asked for 1400 and laid out at 776.
      double width = 1400,
      double height = 400,
    }) async {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: DeviceStrip(
                settings: settings,
                onSet: onSet,
                notice: notice,
                reading: reading,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('draws the nouns and the values, wide', (tester) async {
      await pump(tester, _ios(brightness: 'dark'));

      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('dark'), findsOneWidget);
    });

    testWidgets('a chip tips on a real hover, and not on arriving', (
      tester,
    ) async {
      // A chip is a region that *appears* under a stationary pointer: the bar
      // is drawn empty while the first read is in flight and the chips arrive
      // when it lands. `Tooltip` opens on the synthetic enter that follows,
      // which is the report `_HoverTip` was written for — and this was the one
      // call site still using a bare one.
      var mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(() => mouse.removePointer());

      await pump(tester, const [], reading: true);
      // Park the pointer where a chip is about to be, then let the read land.
      await mouse.moveTo(const Offset(60, 18));
      await tester.pump();
      await pump(tester, _iosDefaults);
      await tester.pump(const Duration(seconds: 1));

      expect(
        _tipsAbout(tester, 'Appearance'),
        isEmpty,
        reason: 'nothing moved the mouse',
      );

      await mouse.moveTo(tester.getCenter(find.text('Theme')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(_tipsAbout(tester, 'Appearance'), ['Appearance: light']);
    });

    testWidgets('a chip still takes a tap while its tip is armed', (
      tester,
    ) async {
      // The tip lives *inside* the tappable, because arming re-parents whatever
      // is directly below it — around the tappable, a hover during a press
      // would rebuild it and the press would go nowhere.
      var mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(() => mouse.removePointer());
      await pump(tester, _iosDefaults);

      await mouse.moveTo(tester.getCenter(find.text('Theme')));
      await tester.pump();
      await tester.tap(find.text('Theme'));
      await tester.pumpAndSettle();

      expect(find.text('Appearance'), findsOneWidget, reason: 'picker opened');
    });

    testWidgets('a bar too narrow for its chips scrolls, and keeps them all', (
      tester,
    ) async {
      // It folded into a `+3` control for three rounds. Scrolling is what the
      // previews top bar next door does, and a chip that is off the edge is
      // still a chip rather than a number.
      await pump(tester, _iosDefaults, width: 300);

      var bar = find.byType(SingleChildScrollView);
      expect(bar, findsOneWidget);
      expect(
        tester.widget<SingleChildScrollView>(bar).scrollDirection,
        Axis.horizontal,
      );
      expect(find.textContaining('+'), findsNothing, reason: 'no fold badge');
      expect(find.text('Device'), findsNothing, reason: 'no label to press');

      // Every chip is built, whether or not the width can show it — which is
      // the difference from the fold, where the ones past the edge were gone.
      for (var noun in ['Theme', 'Text', 'Turn', 'Lang', 'A11y']) {
        expect(find.text(noun), findsOneWidget, reason: noun);
      }
    });

    testWidgets('a chip opens its picker, and Set writes the platform value', (
      tester,
    ) async {
      var written = <(DeviceSettingId, String)>[];
      await pump(tester, _iosDefaults, onSet: (id, v) => written.add((id, v)));

      await tester.tap(find.text('Theme'));
      await tester.pumpAndSettle();
      expect(find.text('Appearance'), findsOneWidget);

      await tester.tap(find.text('dark'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();

      expect(written, [(DeviceSettingId.brightness, 'dark')]);
    });

    testWidgets('the verb carries the cost', (tester) async {
      await pump(tester, _iosDefaults, onSet: (_, _) {});

      await tester.tap(find.text('Lang'));
      await tester.pumpAndSettle();

      expect(find.text('Set and relaunch'), findsOneWidget);
      expect(
        find.textContaining('will not see it until it is launched again'),
        findsWidgets,
        reason: 'the cost is stated above the options as well as on the verb',
      );
    });

    testWidgets('the flags pick and then apply, like every other picker', (
      tester,
    ) async {
      // Write-on-tap was the first shape, and it made this the only control on
      // the strip whose click was final — in the one popover with several
      // things in it.
      var written = <(DeviceSettingId, String)>[];
      await pump(tester, _iosDefaults, onSet: (id, v) => written.add((id, v)));

      await tester.tap(find.text('A11y'));
      await tester.pumpAndSettle();
      expect(find.text('Set'), findsOneWidget);

      // The `on` under `Invert colours`, not the one under `High contrast`.
      await tester.tap(find.text('on').at(1));
      await tester.pumpAndSettle();
      expect(written, isEmpty, reason: 'picked, not written');

      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();
      expect(written, [(DeviceSettingId.invertColors, 'on')]);
    });

    testWidgets('one press applies every flag that moved, and only those', (
      tester,
    ) async {
      var written = <(DeviceSettingId, String)>[];
      await pump(tester, _iosDefaults, onSet: (id, v) => written.add((id, v)));

      await tester.tap(find.text('A11y'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('on').at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('on').at(1));
      await tester.pumpAndSettle();
      // Put one back where it started — it moved and then did not. `off` at
      // index 0 is the *chip on the bar*, which reads `A11y off`; tapping that
      // closes the popover rather than picking anything.
      await tester.tap(find.text('off').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();

      expect(written, [(DeviceSettingId.invertColors, 'on')]);
    });

    testWidgets('a refused flag keeps its reason, one hover away', (
      tester,
    ) async {
      // In a group the whole sentence is a wall: iOS refuses two of four, and
      // three paragraphs and two command boxes buried the two switches the
      // popover exists for. The name stays on screen, the sentence moves into
      // a tooltip, and the by-hand command goes with it.
      await pump(tester, _iosDefaults, onSet: (_, _) {});

      await tester.tap(find.text('A11y'));
      await tester.pumpAndSettle();

      expect(find.text('Not on this device:'), findsOneWidget);
      expect(find.text('Bold text'), findsOneWidget);
      expect(
        find.textContaining('nothing reads'),
        findsNothing,
        reason: 'the paragraph is not drawn in a group',
      );

      // **Nothing pops up until the pointer is moved onto it.** A popover opens
      // under the cursor, and a mouse region appearing beneath a stationary
      // pointer gets a synthetic enter on the next frame — which made a
      // paragraph-sized tooltip appear over the card, unasked, 300ms after it
      // opened.
      expect(_tipsAbout(tester, 'nothing reads'), isEmpty);

      var mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(() => mouse.removePointer());
      await tester.pump();
      await mouse.moveTo(tester.getCenter(find.text('Bold text')));
      await tester.pumpAndSettle();

      var tips = _tipsAbout(tester, 'nothing reads');
      expect(tips, hasLength(1));
      expect(
        tips.single,
        contains('Settings ▸'),
        reason: 'the command rides along',
      );
    });

    testWidgets('a whole setting refused keeps the paragraph', (tester) async {
      // The other half of the same decision: when the refusal is the only
      // thing in the popover there is nothing to crowd, and the sentence and
      // its command are the entire product.
      await pump(tester, [
        const DeviceSetting.unavailable(
          id: DeviceSettingId.orientation,
          noun: 'Turn',
          reason: 'A physical iPhone will not turn on request.',
          command: 'devicectl device info details',
        ),
      ], onSet: (_, _) {});

      await tester.tap(find.text('Turn'));
      await tester.pumpAndSettle();
      expect(find.textContaining('will not turn on request'), findsOneWidget);
      expect(find.text('devicectl device info details'), findsOneWidget);
    });
    Future<void> pumpOne(
      WidgetTester tester,
      DeviceSetting language, {
      void Function(DeviceSettingId, String)? onSet,
    }) async {
      tester.view.physicalSize = const Size(1400, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: DeviceStrip(settings: [language], onSet: onSet),
            ),
          ),
        ),
      );
    }

    testWidgets('offers a field beside them, not instead of them', (
      tester,
    ) async {
      // Drawn as an either/or first — chips where there were options, a field
      // where there were none — and on Android the only "option" is the locale
      // already in force, so the picker offered exactly one choice.
      await tester.runAsync(() async {});
      await pumpOne(tester, _androidLanguage(value: 'fr-FR'), onSet: (_, _) {});

      await tester.tap(find.text('Lang'));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('fr-FR'), findsWidgets);
    });

    testWidgets('can be handed back to the device', (tester) async {
      var written = <(DeviceSettingId, String)>[];
      await pumpOne(
        tester,
        _androidLanguage(value: 'fr-FR'),
        onSet: (id, v) => written.add((id, v)),
      );

      await tester.tap(find.text('Lang'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Device language'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();

      expect(written, [(DeviceSettingId.language, '')]);
    });

    testWidgets('a typed tag is what gets written', (tester) async {
      var written = <(DeviceSettingId, String)>[];
      await pumpOne(
        tester,
        _androidLanguage(value: 'fr-FR'),
        onSet: (id, v) => written.add((id, v)),
      );

      await tester.tap(find.text('Lang'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), ' ja ');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();

      expect(written, [(DeviceSettingId.language, 'ja')]);
    });

    testWidgets('an empty value is refused where clearing means nothing', (
      tester,
    ) async {
      // iOS has no off position: emptying `AppleLanguages` is not "use the
      // default", it is a language list with nothing in it.
      var written = <(DeviceSettingId, String)>[];
      await pumpOne(
        tester,
        _iosDefaults.of(DeviceSettingId.language),
        onSet: (id, v) => written.add((id, v)),
      );

      await tester.tap(find.text('Lang'));
      await tester.pumpAndSettle();
      expect(find.text('Device language'), findsNothing);

      await tester.enterText(find.byType(TextField), '  ');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set and relaunch'));
      await tester.pumpAndSettle();

      expect(written, isEmpty);
    });

    testWidgets('the provenance footnote says when a value is only an echo', (
      tester,
    ) async {
      await pump(tester, _iosDefaults, onSet: (_, _) {});

      await tester.tap(find.text('A11y'));
      await tester.pumpAndSettle();

      // Two words on the card; the command and the measurement behind the same
      // deliberate hover as a refusal's sentence.
      expect(find.textContaining('as written'), findsOneWidget);
      expect(_tipsAbout(tester, 'no command that reports this one'), isEmpty);

      var mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(() => mouse.removePointer());
      await tester.pump();
      await mouse.moveTo(tester.getCenter(find.textContaining('as written')));
      await tester.pumpAndSettle();

      expect(
        _tipsAbout(tester, 'no command that reports this one'),
        hasLength(1),
      );
    });

    testWidgets('nothing to write to leaves the verb dead but readable', (
      tester,
    ) async {
      await pump(tester, _iosDefaults);

      await tester.tap(find.text('Theme'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();

      // No throw, no write, and the reasons are still on screen — the rule the
      // view tabs above already follow: a disabled control stays visible so the
      // page's furniture does not move every time a build starts.
      expect(find.text('Appearance'), findsOneWidget);
    });

    testWidgets('a disagreement gets the line under the bar', (tester) async {
      // Nothing in v1 produces this — every measured disagreement is refused on
      // the platform that has it. It is drawn because the guest extension that
      // reads the app's own MediaQuery is what fills it, and the anatomy should
      // not move when that lands.
      await pump(tester, [
        const DeviceSetting(
          id: DeviceSettingId.disableAnimations,
          noun: 'A11y',
          value: 'on',
          state: DeviceSettingState.notObserved,
        ),
      ]);

      expect(find.textContaining('the app does not carry it'), findsOneWidget);
    });

    testWidgets('a target with no backend is one sentence', (tester) async {
      await pump(
        tester,
        const [],
        notice: 'A physical iPhone answers to devicectl.',
      );

      expect(find.textContaining('devicectl'), findsOneWidget);
      expect(
        find.byType(SingleChildScrollView),
        findsNothing,
        reason:
            'an empty 36-pixel band is furniture claiming to be a control '
            '— the sentence is the whole strip here',
      );
    });

    testWidgets('the bar is there while the first read is in flight', (
      tester,
    ) async {
      // Not drawn empty *forever* — see the no-backend case — but drawn while
      // an answer is coming, so the ordinary case fills a bar that already
      // exists rather than pushing the picture down a second after it opens.
      await pump(tester, const [], reading: true);

      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });

    testWidgets('a quiet strip has no borders to be busy with', (tester) async {
      // Study 2's finding 13: five bordered boxes saying nothing has happened
      // is a busy rendering of a quiet fact.
      await pump(tester, _iosDefaults);
      var quiet = _chipBorders(tester);
      expect(quiet.every((c) => c == Colors.transparent), isTrue);

      await pump(tester, _ios(brightness: 'dark'));
      expect(
        _chipBorders(tester).where((c) => c != Colors.transparent),
        hasLength(1),
        reason: 'the border arrives with the departure, and only there',
      );
    });
  });
}

/// Every mounted tooltip whose message mentions [about].
///
/// By message rather than by type, because the chips on the bar carry tooltips
/// of their own and those are not what any of this is about.
List<String> _tipsAbout(WidgetTester tester, String about) => tester
    .widgetList<Tooltip>(find.byType(Tooltip))
    .map((t) => t.message ?? '')
    .where((m) => m.contains(about))
    .toList();

/// The borders every chip painted, in bar order.
List<Color> _chipBorders(WidgetTester tester) => tester
    .widgetList<Container>(find.byType(Container))
    .map((c) => c.decoration)
    .whereType<BoxDecoration>()
    .where((d) => d.borderRadius != null && d.border is Border)
    .map((d) => (d.border! as Border).top.color)
    .toList();

/// What `SimctlDeviceSettings.read` answers with on an untouched simulator —
/// the same eight rows, in the same order, carrying the same wording. Built by
/// hand rather than read, because the backend's own tests already pin that it
/// produces these and this file is about what is done with them.
List<DeviceSetting> get _iosDefaults => _ios();

List<DeviceSetting> _ios({
  String brightness = 'light',
  String textScale = 'large',
  String highContrast = 'off',
  String invertColors = 'off',
}) => [
  DeviceSetting(
    id: DeviceSettingId.brightness,
    noun: 'Theme',
    value: brightness,
    provenance: DeviceProvenance.answered,
    options: const ['light', 'dark'],
    atDefault: brightness == 'light',
    command: 'xcrun simctl ui X appearance',
  ),
  DeviceSetting(
    id: DeviceSettingId.textScale,
    noun: 'Text',
    value: textScale,
    provenance: DeviceProvenance.answered,
    options: const ['large', 'accessibility-large'],
    atDefault: textScale == 'large',
  ),
  const DeviceSetting(
    id: DeviceSettingId.orientation,
    noun: 'Turn',
    value: 'portrait',
    provenance: DeviceProvenance.derived,
    cost: DeviceCost.takesFocus,
    options: ['portrait', 'landscape'],
    atDefault: true,
  ),
  const DeviceSetting(
    id: DeviceSettingId.language,
    noun: 'Lang',
    value: 'en-US',
    provenance: DeviceProvenance.written,
    cost: DeviceCost.relaunchesApp,
    options: ['en-US', 'fr-BE'],
    openOptions: true,
    atDefault: true,
  ),
  const DeviceSetting.unavailable(
    id: DeviceSettingId.boldText,
    noun: 'A11y',
    reason:
        'Setting bold text invents a key nothing reads: the write succeeds, '
        'the read hands it back, and no app sees it.',
    command: 'Settings ▸ Accessibility ▸ Display & Text Size ▸ Bold Text',
  ),
  DeviceSetting(
    id: DeviceSettingId.highContrast,
    noun: 'A11y',
    value: highContrast,
    provenance: DeviceProvenance.answered,
    options: const ['on', 'off'],
    atDefault: highContrast == 'off',
  ),
  DeviceSetting(
    id: DeviceSettingId.invertColors,
    noun: 'A11y',
    value: invertColors,
    provenance: DeviceProvenance.written,
    options: const ['on', 'off'],
    atDefault: invertColors == 'off',
    note: 'As written: the simulator has no command that reports this one.',
  ),
  const DeviceSetting.unavailable(
    id: DeviceSettingId.disableAnimations,
    noun: 'A11y',
    reason: 'The simulator accepts Reduce Motion and no app sees it.',
  ),
];

/// Android's locale row: app-scoped, free, and the one setting on either target
/// with a real off position.
DeviceSetting _androidLanguage({String? value}) => DeviceSetting(
  id: DeviceSettingId.language,
  noun: 'Lang',
  value: value,
  provenance: DeviceProvenance.answered,
  scope: DeviceScope.app,
  options: [?value],
  openOptions: true,
  clearLabel: 'Device language',
  atDefault: value == null,
);
