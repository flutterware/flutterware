import 'dart:ui' as ui;

import 'package:flutterware/comparison_report.dart';
import 'package:flutterware/src/inspect/node.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/comparison/shot_store.dart';
import 'package:flutterware_app/src/comparison/ui/shot_image.dart';
import 'package:flutterware_app/src/comparison/ui/stage.dart';
import 'package:flutterware_app/src/comparison/ui/step_page.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The eight shapes of finding the detail page has to render, drawn against
/// the real [StepPage] at the width it ships at.
///
/// Step 1 of `2026-08-31-comparison-detail-page-design.md`'s method: enumerate
/// the states before drawing anything, because until they were listed only the
/// first had ever been looked at — and *events only*, the commonest state on
/// the branch that prompted the note, reached production having never been
/// designed.
///
/// Every one of these is the real widget over real decoded frames, so what
/// they show about the split between picture and finding is what ships.
class _NoStore implements ShotStore {
  const _NoStore();

  @override
  Future<Shot?> byKey(String key, {int? width}) async => null;

  @override
  Future<Shot?> byRef(FrameRef ref, {int? width}) async => null;
}

/// A sign-in screen: header, a label, a field with a value, a primary button.
///
/// [moved] shifts the button and darkens it, which is the only thing here that
/// a screenshot can see.
ui.Image _frame({bool moved = false}) {
  var recorder = ui.PictureRecorder();
  var canvas = Canvas(recorder);
  void bar(Rect rect, Color color) => canvas.drawRRect(
    RRect.fromRectAndRadius(rect, const Radius.circular(6)),
    Paint()..color = color,
  );

  canvas
    ..drawRect(
      const Rect.fromLTWH(0, 0, 390, 280),
      Paint()..color = const Color(0xfffdfcfa),
    )
    ..drawRect(
      const Rect.fromLTWH(0, 0, 390, 52),
      Paint()..color = const Color(0xff2b2f36),
    );
  bar(const Rect.fromLTWH(16, 20, 96, 12), const Color(0xffe5e7eb));
  bar(const Rect.fromLTWH(24, 92, 60, 9), const Color(0xffd8dce2));
  bar(const Rect.fromLTWH(24, 112, 320, 14), const Color(0xffe9ecf1));
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(24, moved ? 206 : 194, 340, 38),
      const Radius.circular(8),
    ),
    Paint()..color = moved ? const Color(0xff3b2f7a) : const Color(0xff4c3fa8),
  );
  return recorder.endRecording().toImageSync(390, 280);
}

const _pixelDiff = PixelDiff(
  width: 390,
  height: 280,
  changedPixels: 13600,
  comparedPixels: 390 * 280,
  sizeChanged: false,
  clusters: [DiffRect(x: 24, y: 194, width: 340, height: 50, pixels: 13600)],
);

/// A `TextInput.setClient` as the framework really reports it.
Map<String, Object?> _autofill(String hash) => {
  'channel': 'system',
  'title': 'flutter/textinput TextInput.setClient',
  'data': {
    'arguments': [
      1,
      {
        'autofill': {'uniqueIdentifier': 'EditableText-$hash'},
      },
    ],
  },
};

Map<String, Object?> _request(int status) => {
  'channel': 'network',
  'title': 'POST /session',
  'detail': '$status',
};

InspectNode _node(
  String type, {
  String? description,
  String? key,
  List<InspectNode> children = const [],
}) => InspectNode(
  id: '',
  type: type,
  description: description,
  widgetKey: key,
  createdByLocalProject: true,
  children: children,
);

@Preview(
  name: 'Step page · 1 · pixels moved',
  group: 'Comparison states',
  wrapper: wrapInAppTheme,
)
Widget state1Pixels() => _State(
  item: ComparedItem.of(
    id: 'tap "Sign in"',
    label: 'tap "Sign in"',
    pixels: _pixelDiff,
    tree: TreeDiff.of(
      _node('Padding', description: 'Padding(all: 12.0)'),
      _node('Padding', description: 'Padding(all: 20.0)'),
    ),
  ),
  moved: true,
);

@Preview(
  name: 'Step page · 2 · tree only',
  group: 'Comparison states',
  wrapper: wrapInAppTheme,
)
Widget state2Tree() => _State(
  item: ComparedItem.of(
    id: 'enterText TextField',
    label: 'enterText TextField',
    // A key added to a `Text` — no pixel moves, and the tree is the only
    // channel that can see it. The consumer report this whole thread started
    // from is exactly this case, and its complaint is visible here: the two
    // rows are byte-identical because `_label` spells a key back only when
    // the node has no description, which a `Text` always has.
    tree: TreeDiff.of(
      _node(
        'Column',
        children: [
          _node('Text', description: 'Text("This code is not valid.")'),
        ],
      ),
      _node(
        'Column',
        children: [
          _node(
            'Text',
            description: 'Text("This code is not valid.")',
            key: "[<'codeErrorText'>]",
          ),
        ],
      ),
    ),
  ),
);

@Preview(
  name: 'Step page · 3 · texts only',
  group: 'Comparison states',
  wrapper: wrapInAppTheme,
)
Widget state3Texts() => _State(
  item: ComparedItem.of(
    id: 'Signed in',
    label: 'Signed in',
    baseTexts: const ['Save', 'Account'],
    headTexts: const ['Pay', 'Account'],
  ),
);

@Preview(
  name: 'Step page · 4 · events only',
  group: 'Comparison states',
  wrapper: wrapInAppTheme,
)
Widget state4Events() => _State(
  item: ComparedItem.of(
    id: 'enterText TextField',
    label: 'enterText TextField',
    baseEvents: [_autofill('24793448'), _request(200)],
    headEvents: [_autofill(''), _request(500)],
  ),
);

@Preview(
  name: 'Step page · 5 · nothing changed',
  group: 'Comparison states',
  wrapper: wrapInAppTheme,
)
Widget state5Same() => _State(
  item: ComparedItem.of(id: 'Welcome', label: 'Welcome'),
);

@Preview(
  name: 'Step page · 6 · broke on head',
  group: 'Comparison states',
  wrapper: wrapInAppTheme,
)
Widget state6Broke() => _State(
  item: ComparedItem.of(
    id: 'Order placed',
    label: 'Order placed',
    headRendered: false,
  ),
  head: false,
);

@Preview(
  name: 'Step page · 7 · only on head',
  group: 'Comparison states',
  wrapper: wrapInAppTheme,
)
Widget state7Added() => _State(
  item: const ComparedItem(
    id: 'Confirm the code',
    label: 'Confirm the code',
    state: ComparedState.added,
  ),
  base: false,
);

/// The test moved and the app did not: the step's finder went from an index
/// to a key, and both runs drew the same frame. The state that was designed
/// last and read worst — a `changed` chip over *no changes on any channel*,
/// under two 150-character finder descriptions in a failure's red.
@Preview(
  name: 'Step page · 8 · found another way',
  group: 'Comparison states',
  wrapper: wrapInAppTheme,
)
Widget state8Retargeted() => const _State(
  item: ComparedItem(
    id:
        'tap widget with type "AnswerChip" descending from widget with key '
        '[GlobalKey#] (ignoring all but first)',
    label:
        'tap widget with type "AnswerChip" descending from widget with key '
        '[GlobalKey#] (ignoring all but first)',
    state: ComparedState.same,
    note:
        'the test finds its target another way, and the step did the same '
        'thing: … type "Question" (ignoring all but index 10) … → '
        '… key [GlobalKey#] …',
    retargeted: (
      base:
          'widget with type "AnswerChip" descending from widget with type '
          '"Question" (ignoring all but index 10) (ignoring all but first)',
      head:
          'widget with type "AnswerChip" descending from widget with key '
          '[GlobalKey#] (ignoring all but first)',
    ),
  ),
);

class _State extends StatefulWidget {
  const _State({
    required this.item,
    this.moved = false,
    this.base = true,
    this.head = true,
  });

  final ComparedItem item;

  /// Whether the head frame differs from the base at all.
  final bool moved;
  final bool base;
  final bool head;

  @override
  State<_State> createState() => _StateState();
}

class _StateState extends State<_State> {
  late var _mode = StageMode.sideBySide;
  late final _shots = ShotPair(const _NoStore())
    ..base = widget.base ? Shot(_frame()) : null
    ..head = widget.head ? Shot(_frame(moved: widget.moved)) : null
    ..settled = true;

  @override
  void dispose() {
    _shots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.bg,
    child: SizedBox(
      width: 900,
      height: 700,
      child: StepPage(
        item: widget.item,
        shots: _shots,
        mode: _mode,
        onMode: (mode) => setState(() => _mode = mode),
        onBack: () {},
      ),
    ),
  );
}
