import 'dart:ui' as ui;

import 'package:flutterware/comparison_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/comparison/shot_store.dart';
import 'package:flutterware_app/src/comparison/ui/channel_lines.dart';
import 'package:flutterware_app/src/comparison/ui/shot_image.dart';
import 'package:flutterware_app/src/comparison/ui/stage.dart';
import 'package:flutterware_app/src/comparison/ui/step_page.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The page leads with whatever changed.
///
/// Seven shapes of finding reach this page and only one of them is a picture
/// that moved. The other six were all drawn as *a picture that moved*, which
/// on a `200 → 500` meant 415px of two identical frames over a grey line.
void main() {
  ui.Image frame({int width = 40, int height = 30}) {
    var recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xff334455),
    );
    return recorder.endRecording().toImageSync(width, height);
  }

  ShotPair pair({
    bool base = true,
    bool head = true,
    int width = 40,
    int height = 30,
  }) => ShotPair(_NoStore())
    ..base = base ? Shot(frame(width: width, height: height)) : null
    ..head = head ? Shot(frame(width: width, height: height)) : null
    ..settled = true;

  Future<void> pump(
    WidgetTester tester,
    ComparedItem item, {
    ShotPair? shots,
    double width = 900,
    ValueChanged<StageMode>? onMode,
  }) {
    tester.view.physicalSize = Size(width, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: 700,
            child: StepPage(
              item: item,
              shots: shots ?? pair(),
              mode: StageMode.sideBySide,
              onMode: onMode ?? (_) {},
              onBack: () {},
            ),
          ),
        ),
      ),
    );
  }

  ComparedItem movedWithTree() => ComparedItem.of(
    id: 'Menu',
    pixels: const PixelDiff(
      width: 40,
      height: 30,
      changedPixels: 300,
      comparedPixels: 1200,
      sizeChanged: false,
      clusters: [DiffRect(x: 0, y: 0, width: 10, height: 10, pixels: 300)],
    ),
    tree: TreeDiff([
      for (var n = 0; n < 30; n++)
        TreeDelta(
          kind: TreeDeltaKind.changed,
          path: 'Row › Text("$n")',
          property: 'size',
          base: '10×10',
          head: '12×10',
        ),
    ]),
  );

  ComparedItem eventsOnly() => ComparedItem.of(
    id: 'enterText',
    baseEvents: [
      {'channel': 'network', 'title': 'POST /session', 'detail': '200'},
    ],
    headEvents: [
      {'channel': 'network', 'title': 'POST /session', 'detail': '500'},
    ],
  );

  testWidgets('a finding no picture can show does not lead with pictures', (
    tester,
  ) async {
    await pump(tester, eventsOnly());

    expect(find.text('Frames identical'), findsOne);
    expect(find.byType(ComparisonStage), findsNothing);
    expect(find.textContaining('200'), findsOne);
  });

  // `identical` is a claim, and somebody is eventually going to check it.
  testWidgets('the frames can still be opened', (tester) async {
    await pump(tester, eventsOnly());
    await tester.tap(find.text('Show frames'));
    await tester.pump();

    expect(find.byType(ComparisonStage), findsOne);
    expect(find.text('Hide frames'), findsOne);
  });

  testWidgets('pixels that moved still lead with the pictures', (tester) async {
    await pump(
      tester,
      ComparedItem.of(
        id: 'tap',
        pixels: const PixelDiff(
          width: 40,
          height: 30,
          changedPixels: 300,
          comparedPixels: 1200,
          sizeChanged: false,
          clusters: [DiffRect(x: 0, y: 0, width: 10, height: 10, pixels: 300)],
        ),
      ),
    );

    expect(find.byType(ComparisonStage), findsOne);
    expect(find.text('Frames identical'), findsNothing);
  });

  // One side missing is its own finding and the stage already draws it well:
  // the frame labelled `base only`, the mode pills disabled, the note in red.
  testWidgets('a side that did not render keeps the stage', (tester) async {
    await pump(
      tester,
      ComparedItem.of(id: 'Order placed', headRendered: false),
      shots: pair(head: false),
    );

    expect(find.byType(ComparisonStage), findsOne);
    expect(find.text('Frames identical'), findsNothing);
  });

  // A portrait frame is bound by the pane's height, so the channels under it
  // took the picture's rows; beside it, they cost the picture nothing.
  testWidgets('the channels stand beside portrait frames on a wide pane', (
    tester,
  ) async {
    await pump(
      tester,
      movedWithTree(),
      shots: pair(width: 30, height: 60),
      width: 1300,
    );

    var stage = tester.getRect(find.byType(ComparisonStage));
    var channels = tester.getRect(find.byType(ChannelLines));
    expect(channels.left, greaterThanOrEqualTo(stage.right));
    expect(channels.top, lessThan(stage.bottom));
  });

  testWidgets('and under landscape ones, which are bound by width instead', (
    tester,
  ) async {
    await pump(tester, movedWithTree(), width: 1300);

    var stage = tester.getRect(find.byType(ComparisonStage));
    var channels = tester.getRect(find.byType(ChannelLines));
    expect(channels.top, greaterThanOrEqualTo(stage.bottom));
  });

  testWidgets('a long tree shows its first rows and the rest on request', (
    tester,
  ) async {
    await pump(tester, movedWithTree());

    expect(find.text('Show 6 more'), findsOne);
    await tester.tap(find.byKey(channelShowAllKey));
    await tester.pump();

    expect(find.byKey(channelShowAllKey), findsNothing);
    await tester.scrollUntilVisible(
      find.textContaining('Text("29")'),
      100,
      scrollable: find
          .descendant(
            of: find.byType(ChannelLines),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.textContaining('Text("29")'), findsOne);
  });

  // The pane is one of several things on screen; the window is the one place
  // a phone frame is big enough to judge a small change on.
  testWidgets('the frames open over the whole window, in the same mode', (
    tester,
  ) async {
    var picked = <StageMode>[];
    await pump(tester, movedWithTree(), onMode: picked.add);

    await tester.tap(find.byKey(enlargeStageKey));
    await tester.pumpAndSettle();
    expect(find.byKey(enlargedStageKey), findsOne);
    expect(
      find.descendant(
        of: find.byKey(enlargedStageKey),
        matching: find.byKey(enlargeStageKey),
      ),
      findsNothing,
      reason: 'the window has nowhere bigger to go',
    );

    await tester.tap(
      find.descendant(
        of: find.byKey(enlargedStageKey),
        matching: find.byKey(stageModeKey(StageMode.onion)),
      ),
    );
    await tester.pump();
    expect(picked, [StageMode.onion]);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(enlargedStageKey), findsNothing);
  });

  testWidgets('a step where nothing moved says so in words', (tester) async {
    await pump(tester, ComparedItem.of(id: 'Welcome'));

    expect(find.text('No changes on any channel'), findsOne);
  });
}

class _NoStore implements ShotStore {
  @override
  Future<Shot?> byKey(String key, {int? width}) async => null;

  @override
  Future<Shot?> byRef(FrameRef ref, {int? width}) async => null;
}
