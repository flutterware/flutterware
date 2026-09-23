import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/preview_popover.dart';
import 'package:flutterware_app/src/previews/thumbnails.dart';
import 'package:flutterware_app/src/ui/design/design.dart';

import 'shell.dart';

const _entry = CatalogEntry(
  path: 'tool/catalog/demos/command_palette.dart',
  symbol: 'paletteResults',
  annotation: "Preview(name: 'Results')",
  name: 'Results',
);

/// The row the popover is pointing at, drawn so the arrow has something to
/// touch — this is the one control whose whole job is where it sits.
const _row = Rect.fromLTWH(0, 300, 260, 26);

@Preview(name: 'Panel-shaped picture', wrapper: wrapInApp)
Widget popoverPanel() => _Stage(thumbnail: ThumbnailReady(_shot(900, 700)));

/// The other shape a catalog holds, and the one the width has to survive: a
/// phone is taller than the popover is allowed to be, so the picture gives up
/// width rather than the popover giving up its edges.
@Preview(name: 'Phone-shaped picture', wrapper: wrapInApp)
Widget popoverPhone() => _Stage(thumbnail: ThumbnailReady(_shot(375, 667)));

/// The cold wait, which is the long one — a catalog nobody has compiled yet.
@Preview(name: 'Compiling', wrapper: wrapInApp)
Widget popoverCompiling() =>
    const _Stage(thumbnail: ThumbnailPending(compiling: true));

@Preview(name: 'Rendering', wrapper: wrapInApp)
Widget popoverRendering() =>
    const _Stage(thumbnail: ThumbnailPending(compiling: false));

/// A demo that would not build. The compiler's words are the answer and there
/// is no picture worth showing beside them.
@Preview(name: 'Would not compile', wrapper: wrapInApp)
Widget popoverFailed() => const _Stage(
  thumbnail: ThumbnailFailed(
    'tool/catalog/demos/does_not_compile.dart:13:28: Error: Method not '
    "found: 'ThisTypeDoesNotExist'.\n"
    '    return ThisTypeDoesNotExist();\n'
    '           ^^^^^^^^^^^^^^^^^^^^^',
  ),
);

/// The last row in a long list. The body is pushed up to stay in the window
/// and the arrow stays on the row, which is the pair the layout exists for.
@Preview(name: 'Against the bottom edge', wrapper: wrapInApp)
Widget popoverClamped() => _Stage(
  row: const Rect.fromLTWH(0, 668, 260, 26),
  thumbnail: ThumbnailReady(_shot(900, 700)),
);

/// The popover over a stand-in for the list it belongs beside.
class _Stage extends StatelessWidget {
  const _Stage({this.row = _row, required this.thumbnail});

  final Rect row;
  final Thumbnail thumbnail;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      body: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: row.width,
            child: ColoredBox(color: colors.panel),
          ),
          Positioned.fromRect(
            rect: row,
            child: ColoredBox(color: colors.accentSoft),
          ),
          PreviewPopover(entry: _entry, anchor: row, thumbnail: thumbnail),
        ],
      ),
    );
  }
}

/// A stand-in screenshot at [width]×[height], so each face is a picture of a
/// known shape rather than of whatever the machine happened to render.
ui.Image _shot(int width, int height) {
  var recorder = ui.PictureRecorder();
  var canvas = Canvas(recorder);
  var size = Size(width.toDouble(), height.toDouble());
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF6F7F9));
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.width, 56),
    Paint()..color = const Color(0xFF1B6EF3),
  );
  for (var i = 0; i < 6; i++) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(24, 88 + i * 56, size.width - 48, 40),
        const Radius.circular(6),
      ),
      Paint()..color = const Color(0xFFE3E6EB),
    );
  }
  return recorder.endRecording().toImageSync(width, height);
}
