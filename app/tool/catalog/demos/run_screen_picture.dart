import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
import 'package:flutterware_app/src/run/screen_picture.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The run cockpit's picture pane, with the hovered node's box over it.
///
/// What this is for. The box is drawn by hovering a row in the tree beside
/// it, and a hover is the one thing the drive loop cannot produce — so in the
/// running studio there is no way to *look* at this at all without a hand on
/// the mouse. Here the highlight is a `ValueNotifier` set to a node id, which
/// is the same state a hover puts it in.
///
/// What there is to judge: whether a 1px accent stroke and an 18% fill read
/// against a screenshot of a real app rather than a flat colour, whether the
/// label sits where it can be read at a picture a third of the pane wide, and
/// what happens to a box on a node that reaches the picture's edge.
@Preview(name: 'Screen picture', group: 'Run cockpit', wrapper: wrapInAppTheme)
Widget screenPicture() => const _Sheet();

@Preview(
  name: 'Screen picture · dark',
  group: 'Run cockpit',
  wrapper: wrapInDarkTheme,
)
Widget screenPictureDark() => const _Sheet();

/// Two widths, because the width is what the box is scaled by — the pane's
/// grip goes from a thumbnail to most of the tab — and two nodes, because the
/// label has room above one of them and not the other.
class _Sheet extends StatelessWidget {
  const _Sheet();

  @override
  Widget build(BuildContext context) => Container(
    color: context.colors.panel2,
    padding: const EdgeInsets.all(24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The `AppBar` sits on the top edge, so its label has nowhere above to
        // go and drops inside the box.
        for (var (width, node) in [(220.0, '0'), (380.0, '0/1')]) ...[
          SizedBox(
            width: width,
            height: 420,
            child: RunScreenPicture(
              picture: _fakeApp(),
              undecodable: false,
              loading: false,
              // What a hover puts there.
              highlight: ValueNotifier(node),
              tree: _tree,
              canvas: RunScreenPicture.canvasOf(_tree),
            ),
          ),
          const SizedBox(width: 24),
        ],
      ],
    ),
  );
}

/// A phone-shaped app: a bar, a card, and a button on the bottom edge.
///
/// Drawn rather than loaded, so the demo needs no asset and no decode — and
/// `toImageSync` means it is there in the first frame rather than one future
/// later, which is what makes this previewable at all.
ui.Image _fakeApp() {
  const width = 390.0;
  const height = 844.0;
  var recorder = ui.PictureRecorder();
  // **Scaled before anything is drawn.** `toImageSync` rasterises the picture
  // at 1:1 into the bitmap it is given — it does not fit one to the other — so
  // without this the app is drawn into the top-left quarter of a 2× image and
  // every box lands somewhere the drawing is not. Which is what the first
  // version of this demo looked like, and it read as a broken highlight rather
  // than a broken fixture.
  var canvas = Canvas(recorder)
    ..scale(2)
    ..drawRect(
      const Rect.fromLTWH(0, 0, width, height),
      Paint()..color = const Color(0xFFF3F4F6),
    )
    ..drawRect(
      const Rect.fromLTWH(0, 0, width, 96),
      Paint()..color = const Color(0xFF1D4ED8),
    )
    ..drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(24, 140, 342, 220),
        const Radius.circular(12),
      ),
      Paint()..color = Colors.white,
    );
  for (var i = 0; i < 3; i++) {
    canvas.drawRect(
      Rect.fromLTWH(48, 180.0 + i * 40, 220 - i * 40, 14),
      Paint()..color = const Color(0xFFD1D5DB),
    );
  }
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(24, 760, 342, 56),
      const Radius.circular(28),
    ),
    Paint()..color = const Color(0xFF1D4ED8),
  );
  return recorder.endRecording().toImageSync(
    (width * 2).round(),
    (height * 2).round(),
  );
}

/// The tree the picture was read with — `MyApp` is the canvas and the rest
/// are what the two columns light up.
const _tree = InspectTree(
  entryId: null,
  root: InspectNode(
    id: '',
    type: 'MyApp',
    createdByLocalProject: true,
    layout: InspectLayout(x: 0, y: 0, width: 390, height: 844),
    children: [
      InspectNode(
        id: '0',
        type: 'AppBar',
        createdByLocalProject: true,
        layout: InspectLayout(x: 0, y: 0, width: 390, height: 96),
      ),
      InspectNode(
        id: '0/1',
        type: 'ReceiptCard',
        createdByLocalProject: true,
        layout: InspectLayout(x: 24, y: 140, width: 342, height: 220),
      ),
      InspectNode(
        id: '0/2',
        type: 'FilledButton',
        createdByLocalProject: true,
        layout: InspectLayout(x: 24, y: 760, width: 342, height: 56),
      ),
    ],
  ),
);
