import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/ui/capture_button.dart';
import 'package:flutterware_app/src/utils/image_clipboard.dart';

// **All four drive the copy branch, which exists only where the clipboard
// channel does.** Off macOS the button ships its other half — save as the
// primary action — so there is no `content_copy` to tap and no "Copy …" row to
// read, and every assertion below would be describing a widget that is
// correctly absent. Skipped rather than rewritten: what they pin is the branch
// that ships, and it ships where the runner implementing the channel is built.
void main() {
  // `testWidgets` takes a bool here, so the reason is the comment above.
  var noChannel = !ImageClipboard.isSupported;
  var clipboard = <Uint8List>[];

  Future<void> pump(
    WidgetTester tester, {
    required CaptureTarget primary,
    List<CaptureTarget> secondary = const [],
    bool enabled = true,
  }) async {
    clipboard = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutterware/clipboard'),
      (call) async {
        clipboard.add((call.arguments as Map)['png'] as Uint8List);
        return true;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CaptureButton(
              primary: primary,
              secondary: secondary,
              enabled: enabled,
              shortcutHint: '⌘⇧C',
            ),
          ),
        ),
      ),
    );
  }

  CaptureTarget target(
    String label,
    List<int> bytes, {
    ValueChanged<bool>? onHover,
  }) => CaptureTarget(
    label: label,
    capture: () async => Uint8List.fromList(bytes),
    suggestedName: () => 'shot.png',
    onHover: onHover,
  );

  testWidgets('a click copies the primary target and ticks', (tester) async {
    await pump(tester, primary: target('the preview', [1, 2, 3]));

    await tester.tap(find.byIcon(Icons.content_copy));
    await tester.pump();

    expect(clipboard, [
      [1, 2, 3],
    ]);
    // The tick, then the button back — a press must be visible, and must not
    // be permanent.
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
  }, skip: noChannel);

  testWidgets('the menu names every target, primary first', (tester) async {
    await pump(
      tester,
      primary: target('the preview', [1]),
      secondary: [
        target('just "Card"', [2]),
      ],
    );

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();

    expect(find.text('Copy the preview'), findsOneWidget);
    expect(find.text('Save the preview as PNG…'), findsOneWidget);
    expect(find.text('Copy just "Card"'), findsOneWidget);
    expect(find.text('Save just "Card" as PNG…'), findsOneWidget);

    await tester.tap(find.text('Copy just "Card"'));
    await tester.pumpAndSettle();
    expect(clipboard, [
      [2],
    ]);
  }, skip: noChannel);

  testWidgets('dismissing the menu un-hovers a previewing target', (
    tester,
  ) async {
    var hovers = <bool>[];
    await pump(
      tester,
      primary: target('the preview', [1]),
      secondary: [
        target('just "Card"', [2], onHover: hovers.add),
      ],
    );

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();

    var mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.text('Copy just "Card"')));
    await tester.pumpAndSettle();
    expect(hovers, [true]);

    // Escape closes the menu with the pointer still over the row — the exact
    // path where no exit event ever fires.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(hovers.last, false);
  }, skip: noChannel);

  testWidgets('a null capture is a quiet refusal', (tester) async {
    await pump(
      tester,
      primary: CaptureTarget(
        label: 'the preview',
        capture: () async => null,
        suggestedName: () => 'shot.png',
      ),
    );

    await tester.tap(find.byIcon(Icons.content_copy));
    await tester.pump();

    expect(clipboard, isEmpty);
    expect(find.byIcon(Icons.check), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  }, skip: noChannel);
}
