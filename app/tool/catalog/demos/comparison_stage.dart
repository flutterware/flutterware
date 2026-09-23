import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutterware/comparison_report.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/comparison/shot_store.dart';
import 'package:flutterware_app/src/comparison/ui/shot_image.dart';
import 'package:flutterware_app/src/comparison/ui/stage.dart';

import 'app_theme.dart';

/// The comparison stage over a staged pair of frames: a button that moved
/// 12px down and changed shade, and a badge that appeared.
///
/// What this is for. The stage only ever appears after a comparison run,
/// which prices a look at it in minutes; here the two frames are drawn on a
/// canvas and the diff is written by hand to match, so every mode — the boxes
/// on the head half, the slider's boundary, the pills' hover — is one preview
/// away. The pills are live: pick a mode and it switches.
class _NoStore implements ShotStore {
  const _NoStore();

  @override
  Future<Shot?> byKey(String key, {int? width}) async => null;

  @override
  Future<Shot?> byRef(FrameRef ref, {int? width}) async => null;
}

@Preview(name: 'Comparison stage', group: 'Comparison', wrapper: wrapInAppTheme)
Widget comparisonStage() => const _Demo();

@Preview(
  name: 'Comparison stage · pixels',
  group: 'Comparison',
  wrapper: wrapInAppTheme,
)
Widget comparisonStagePixels() => const _Demo(mode: StageMode.pixels);

@Preview(
  name: 'Comparison stage · dark',
  group: 'Comparison',
  wrapper: wrapInDarkTheme,
)
Widget comparisonStageDark() => const _Demo();

class _Demo extends StatefulWidget {
  const _Demo({this.mode = StageMode.sideBySide});

  final StageMode mode;

  @override
  State<_Demo> createState() => _DemoState();
}

class _DemoState extends State<_Demo> {
  late var _mode = widget.mode;

  late final _shots = ShotPair(const _NoStore())
    ..base = Shot(_frame(head: false))
    ..head = Shot(_frame(head: true))
    ..settled = true;

  /// Written to match what [_frame] draws: the button's old and new places as
  /// one union box, the badge as its own.
  static const _diff = PixelDiff(
    width: 390,
    height: 280,
    changedPixels: 6300,
    comparedPixels: 390 * 280,
    sizeChanged: false,
    clusters: [
      DiffRect(x: 24, y: 200, width: 120, height: 48, pixels: 6100),
      DiffRect(x: 348, y: 20, width: 16, height: 16, pixels: 200),
    ],
  );

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 860,
    height: 480,
    child: ComparisonStage(
      shots: _shots,
      mode: _mode,
      onMode: (mode) => setState(() => _mode = mode),
      diff: _diff,
    ),
  );

  @override
  void dispose() {
    _shots.dispose();
    super.dispose();
  }
}

/// A little app screen: header, three lines of "text", a primary button. The
/// head moves the button down 12px, darkens it, and grows a badge.
ui.Image _frame({required bool head}) {
  var recorder = ui.PictureRecorder();
  var canvas = Canvas(recorder);
  void bar(Rect rect, Color color) => canvas.drawRRect(
    RRect.fromRectAndRadius(rect, const Radius.circular(6)),
    Paint()..color = color,
  );

  canvas
    ..drawRect(
      const Rect.fromLTWH(0, 0, 390, 280),
      Paint()..color = const Color(0xffffffff),
    )
    ..drawRect(
      const Rect.fromLTWH(0, 0, 390, 56),
      Paint()..color = const Color(0xff1f2937),
    );
  bar(const Rect.fromLTWH(16, 22, 120, 12), const Color(0xffe5e7eb));
  bar(const Rect.fromLTWH(24, 88, 340, 12), const Color(0xffd1d5db));
  bar(const Rect.fromLTWH(24, 116, 300, 12), const Color(0xffd1d5db));
  bar(const Rect.fromLTWH(24, 144, 260, 12), const Color(0xffd1d5db));
  if (head) {
    canvas.drawCircle(
      const Offset(356, 28),
      7,
      Paint()..color = const Color(0xffef4444),
    );
  }
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(24, head ? 212 : 200, 120, 36),
      const Radius.circular(8),
    ),
    Paint()..color = head ? const Color(0xff1d4ed8) : const Color(0xff3b82f6),
  );
  return recorder.endRecording().toImageSync(390, 280);
}

/// The same stage over a **text** diff — the case the boxes are hardest at.
///
/// A body of copy set 0.4px smaller shatters into a component per glyph
/// fragment: hundreds of boxes, none of them overlapping, drawn over the
/// paragraph they are supposed to point at. Written as a live diff rather than
/// by hand because that scatter is exactly what cannot be faked convincingly.
@Preview(
  name: 'Comparison stage · text · pixels',
  group: 'Comparison',
  wrapper: wrapInAppTheme,
)
Widget comparisonStageText() => const _TextDemo(mode: StageMode.pixels);

@Preview(
  name: 'Comparison stage · text',
  group: 'Comparison',
  wrapper: wrapInAppTheme,
)
Widget comparisonStageTextSideBySide() => const _TextDemo();

class _TextDemo extends StatefulWidget {
  const _TextDemo({this.mode = StageMode.sideBySide});

  final StageMode mode;

  @override
  State<_TextDemo> createState() => _TextDemoState();
}

class _TextDemoState extends State<_TextDemo> {
  late var _mode = widget.mode;

  late final _base = _textFrame(head: false);
  late final _head = _textFrame(head: true);
  late final _shots = ShotPair(const _NoStore())
    ..base = Shot(_base)
    ..head = Shot(_head)
    ..settled = true;

  PixelDiff? _diff;

  @override
  void initState() {
    super.initState();
    unawaited(_compare());
  }

  Future<void> _compare() async {
    var base = await _base.toByteData(format: ui.ImageByteFormat.rawRgba);
    var head = await _head.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (!mounted) return;
    setState(() {
      _diff = PixelDiff.of(
        base: base!.buffer.asUint8List(),
        baseWidth: _base.width,
        baseHeight: _base.height,
        head: head!.buffer.asUint8List(),
        headWidth: _head.width,
        headHeight: _head.height,
      );
    });
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 860,
    height: 480,
    child: ComparisonStage(
      shots: _shots,
      mode: _mode,
      onMode: (mode) => setState(() => _mode = mode),
      diff: _diff,
    ),
  );

  @override
  void dispose() {
    _shots.dispose();
    super.dispose();
  }
}

/// A page of copy, set 0.4px smaller on the head — a font change, which is the
/// diff that shatters.
ui.Image _textFrame({required bool head}) {
  var recorder = ui.PictureRecorder();
  var canvas = Canvas(recorder)
    ..drawRect(
      const Rect.fromLTWH(0, 0, 390, 280),
      Paint()..color = const Color(0xffffffff),
    );

  var builder =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(
            fontSize: head ? 13.6 : 14,
            height: 1.5,
            textAlign: TextAlign.left,
          ),
        )
        ..pushStyle(
          ui.TextStyle(
            color: const Color(0xff111827),
            fontWeight: FontWeight.w600,
            fontSize: head ? 17.5 : 18,
          ),
        )
        ..addText('Release notes\n')
        ..pop()
        ..pushStyle(ui.TextStyle(color: const Color(0xff374151)))
        ..addText(
          'The picker now remembers the last folder it was pointed at, and a '
          'run that ends while the panel is closed no longer keeps its frames '
          'around. Two crashes on startup are fixed: one when the cache was '
          'written by an older build, one when the window opened on a display '
          'that had gone away.',
        );

  var paragraph = builder.build()
    ..layout(const ui.ParagraphConstraints(width: 358));
  canvas.drawParagraph(paragraph, const Offset(16, 20));

  // Something that is not text, so the picture is not only the shattered case:
  // a status chip that changed colour.
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(16, 236, 96, 26),
      const Radius.circular(13),
    ),
    Paint()..color = head ? const Color(0xff16a34a) : const Color(0xff9ca3af),
  );

  return recorder.endRecording().toImageSync(390, 280);
}
